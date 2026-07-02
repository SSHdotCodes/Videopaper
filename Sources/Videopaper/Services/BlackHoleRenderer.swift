import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd

/// Live, real-time renderer for the "Black Hole" wallpaper preset.
///
/// Metal port of the Schwarzschild geodesic ray tracer from
/// ~/black-hole-cpp-fable5 (same shader, same quality, same 60 fps):
///   * per-pixel RK4 integration of the exact null-geodesic (Binet) equation
///     d2u/dphi2 = 3u^2 - u in each photon's orbital plane
///   * analytic equatorial-crossing detection + cubic Hermite refinement, so
///     the photon ring and higher-order disk images come out of the integrator
///   * Novikov-Thorne disk temperature, exact Doppler + gravitational redshift
///     g = sqrt(1-3M/r) / ((1 - Omega Lz) sqrt(f_cam)), beaming I ~ g^4,
///     Planck-spectrum colors, turbulence sheared by differential rotation
///   * HDR (rgba16Float) scene -> bright pass -> 8x separable Gaussian ping-pong
///     -> ACES composite, for the bloom halos
///
/// It runs as a `CAMetalLayer` driven by a `CVDisplayLink` so it animates as a
/// desktop wallpaper.
final class BlackHoleRenderer {
    let metalLayer = CAMetalLayer()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var link: CVDisplayLink?

    private let lock = NSLock()
    private var running = false
    private var paused = false
    private let startTime = CFAbsoluteTimeGetCurrent()
    private var pixelSize = CGSize(width: 16, height: 16)
    private var lastFrameHostTime = CFAbsoluteTime(0)

    // Intermediate targets for the bloom chain; rebuilt only when the drawable
    // size changes (never per frame — no allocation churn on the render thread).
    private var sceneTex: MTLTexture?
    private var bloomTex: [MTLTexture] = []
    private var allocatedSize = CGSize.zero

    private struct Uniforms { var res: SIMD2<Float>; var time: Float; var pad: Float }
    private struct PostUniforms { var size: SIMD2<Float>; var dir: SIMD2<Float> }
    /// Cap render resolution: ~2560 px wide matches the quality the shader was
    /// tuned at (measured ~4.4 ms/frame at 2560x1600 on an M4 Max) while
    /// `resizeAspectFill` covers larger panels.
    private let maxDrawableWidth: CGFloat = 2560
    /// Render at 60 fps: full smoothness for the disk/lensing motion while
    /// halving GPU work on 120 Hz ProMotion panels (the display link fires at
    /// panel refresh; the limiter below drops every other callback there and
    /// passes every callback on 60 Hz displays).
    private let targetFrameInterval: CFTimeInterval = 1.0 / 60.0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: BlackHoleRenderer.shaderSource, options: nil)
            func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                guard let vfn = library.makeFunction(name: "bh_vertex"),
                      let ffn = library.makeFunction(name: fragment) else {
                    throw NSError(domain: "BlackHoleRenderer", code: 1)
                }
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vfn
                desc.fragmentFunction = ffn
                desc.colorAttachments[0].pixelFormat = format
                return try device.makeRenderPipelineState(descriptor: desc)
            }
            scenePipeline = try pipeline("bh_scene", format: .rgba16Float)
            brightPipeline = try pipeline("bh_bright", format: .rgba16Float)
            blurPipeline = try pipeline("bh_blur", format: .rgba16Float)
            compositePipeline = try pipeline("bh_composite", format: .bgra8Unorm)
        } catch {
            NSLog("BlackHoleRenderer: pipeline build failed: \(error)")
            return nil
        }

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sdesc) else { return nil }
        self.sampler = sampler

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .resizeAspectFill
        metalLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Two drawables suffice for a wallpaper (no user-visible latency
        // requirement); saves one full-resolution BGRA buffer.
        metalLayer.maximumDrawableCount = 2
    }

    /// Insert the metal layer into a parent scene layer and start rendering.
    func attach(to parent: CALayer, bounds: CGRect, scale: CGFloat) {
        updateFrame(bounds: bounds, scale: scale)
        parent.addSublayer(metalLayer)
        start()
    }

    func updateFrame(bounds: CGRect, scale: CGFloat) {
        lock.lock()
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        let pw = max(bounds.width * scale, 16)
        let ph = max(bounds.height * scale, 16)
        let shrink = min(1.0, maxDrawableWidth / max(pw, ph))
        pixelSize = CGSize(width: (pw * shrink).rounded(), height: (ph * shrink).rounded())
        metalLayer.drawableSize = pixelSize
        lock.unlock()
    }

    private func start() {
        guard link == nil else { return }
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            let me = Unmanaged<BlackHoleRenderer>.fromOpaque(context!).takeUnretainedValue()
            me.render()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(dl, callback, Unmanaged.passUnretained(self).toOpaque())
        link = dl
        running = true
        if !paused {
            CVDisplayLinkStart(dl)
        }
    }

    func stop() {
        if let link {
            CVDisplayLinkStop(link)
        }
        lock.lock()                 // ensure no render() in flight before we drop refs
        running = false
        link = nil
        lock.unlock()
        metalLayer.removeFromSuperlayer()
    }

    /// Halt the display link entirely while the wallpaper is occluded (fullscreen
    /// apps, screen lock). A stopped link means zero CPU/GPU work AND no
    /// nextDrawable() churn on an invisible layer — the latter is what leaked
    /// Mach ports (~1/s) during long occlusions and eventually exhausted the
    /// system pool Metal shared events allocate from, breaking Metal system-wide.
    func setPaused(_ newValue: Bool) {
        lock.lock()
        let changed = paused != newValue
        paused = newValue
        let linkRef = link
        lock.unlock()
        guard changed, let linkRef, running else { return }
        if newValue {
            CVDisplayLinkStop(linkRef)
        } else {
            CVDisplayLinkStart(linkRef)
        }
    }

    private func rebuildTargetsIfNeeded() {
        guard allocatedSize != pixelSize || sceneTex == nil else { return }
        func hdrTexture(width: Int, height: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: max(width, 1), height: max(height, 1),
                mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        sceneTex = hdrTexture(width: w, height: h)
        bloomTex = [hdrTexture(width: w / 2, height: h / 2),
                    hdrTexture(width: w / 2, height: h / 2)].compactMap { $0 }
        allocatedSize = pixelSize
    }

    private func render() {
        lock.lock()
        defer { lock.unlock() }
        guard running, !paused, pixelSize.width > 1 else { return }
        // Frame limiter: the display link fires at panel refresh (up to 120 Hz);
        // render at most every targetFrameInterval.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameHostTime >= targetFrameInterval * 0.92 else { return }
        lastFrameHostTime = now

        rebuildTargetsIfNeeded()
        guard let sceneTex, bloomTex.count == 2,
              let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }

        func pass(target: MTLTexture, pipeline: MTLRenderPipelineState,
                  encode: (MTLRenderCommandEncoder) -> Void) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentSamplerState(sampler, index: 0)
            encode(enc)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        let bw = Float(bloomTex[0].width), bh = Float(bloomTex[0].height)
        let time = Float(now - startTime)

        // 1. HDR geodesic ray-trace
        pass(target: sceneTex, pipeline: scenePipeline) { enc in
            var u = Uniforms(res: SIMD2(Float(sceneTex.width), Float(sceneTex.height)),
                             time: time, pad: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
        // 2. bloom bright pass at half resolution
        pass(target: bloomTex[0], pipeline: brightPipeline) { enc in
            var u = PostUniforms(size: SIMD2(bw, bh), dir: .zero)
            enc.setFragmentBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 0)
            enc.setFragmentTexture(sceneTex, index: 0)
        }
        // 3. separable Gaussian ping-pong
        var cur = 0
        for i in 0..<8 {
            let nxt = 1 - cur
            pass(target: bloomTex[nxt], pipeline: blurPipeline) { enc in
                var u = PostUniforms(size: SIMD2(bw, bh),
                                     dir: i % 2 == 0 ? SIMD2(1.6 / bw, 0) : SIMD2(0, 1.6 / bh))
                enc.setFragmentBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.setFragmentTexture(bloomTex[cur], index: 0)
            }
            cur = nxt
        }
        // 4. composite + ACES tonemap to the drawable
        pass(target: drawable.texture, pipeline: compositePipeline) { enc in
            var u = PostUniforms(size: SIMD2(Float(drawable.texture.width),
                                             Float(drawable.texture.height)), dir: .zero)
            enc.setFragmentBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 0)
            enc.setFragmentTexture(sceneTex, index: 0)
            enc.setFragmentTexture(bloomTex[cur], index: 1)
        }

        cb.present(drawable)
        cb.commit()
    }

    deinit { if let link { CVDisplayLinkStop(link) } }

    // MARK: - Metal Shading Language: Schwarzschild geodesic ray tracer
    // Direct port of black-hole-cpp-fable5/shaders/{blackhole,bright,blur,composite}.frag.
    // Geometric units G = c = M = 1: horizon r = 2, photon sphere r = 3, ISCO r = 6.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 res; float time; float pad; };
    struct PostUniforms { float2 size; float2 dir; };
    struct VOut { float4 pos [[position]]; };

    vertex VOut bh_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        VOut o; o.pos = float4(p, 0.0, 1.0); return o;
    }

    constant float PI         = 3.14159265358979;
    constant float U_CAP      = 0.5;          // 1/r at the event horizon (r = 2M)
    constant float R_ISCO     = 6.0;
    constant float R_DISK_OUT = 16.0;
    constant float U_ESC      = 1.0 / 150.0;
    constant float PHI_MAX    = 20.0;
    constant int   MAX_STEPS  = 600;

    // ------------------------------------------------------------- noise ---
    static float hash13(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }
    static float3 hash33(float3 p) {
        p = fract(p * float3(0.1031, 0.1030, 0.0973));
        p += dot(p, p.yxz + 33.33);
        return fract((p.xxy + p.yxx) * p.zyx);
    }
    static float vnoise(float3 p) {
        float3 ip = floor(p), fp = fract(p);
        float3 s = fp * fp * (3.0 - 2.0 * fp);
        float n000 = hash13(ip);
        float n100 = hash13(ip + float3(1, 0, 0));
        float n010 = hash13(ip + float3(0, 1, 0));
        float n110 = hash13(ip + float3(1, 1, 0));
        float n001 = hash13(ip + float3(0, 0, 1));
        float n101 = hash13(ip + float3(1, 0, 1));
        float n011 = hash13(ip + float3(0, 1, 1));
        float n111 = hash13(ip + float3(1, 1, 1));
        float xy0 = mix(mix(n000, n100, s.x), mix(n010, n110, s.x), s.y);
        float xy1 = mix(mix(n001, n101, s.x), mix(n011, n111, s.x), s.y);
        return mix(xy0, xy1, s.z);
    }
    static float fbm(float3 p) {
        float a = 0.5, s = 0.0;
        for (int i = 0; i < 5; i++) {
            s += a * vnoise(p);
            p = p * 2.03 + float3(11.7, 5.3, 7.9);
            a *= 0.55;
        }
        return s;
    }

    // ---------------------------------------------- Planck (blackbody) -----
    static float3 blackbody(float T) {
        T = clamp(T, 1000.0, 40000.0);
        float t = T / 100.0;
        float3 c;
        c.r = (t <= 66.0) ? 1.0 : clamp(1.29293 * pow(t - 60.0, -0.1332047), 0.0, 1.0);
        c.g = (t <= 66.0) ? clamp(0.39008 * log(t) - 0.63184, 0.0, 1.0)
                          : clamp(1.12989 * pow(t - 60.0, -0.0755148), 0.0, 1.0);
        c.b = (t >= 66.0) ? 1.0
            : ((t <= 19.0) ? 0.0 : clamp(0.54323 * log(t - 10.0) - 1.19625, 0.0, 1.0));
        return pow(c, float3(2.2));
    }

    // ----------------------------------------------------- background ------
    static float3 starLayer(float3 d, float S, float density, float bright) {
        float3 cell = floor(d * S);
        float3 h = hash33(cell);
        if (h.x > density) return float3(0.0);
        float3 sp = normalize((cell + 0.15 + 0.70 * hash33(cell + 17.0)) / S);
        float ca = clamp(dot(d, sp), -1.0, 1.0);
        float ang = acos(ca);
        float sigma = 0.0006 + 0.0013 * h.y * h.y;
        float I = exp(-ang * ang / (2.0 * sigma * sigma));
        float lum = bright * (0.10 + 1.8 * h.z * h.z * h.z * h.z);
        float Tstar = mix(3000.0, 14000.0, h.z);
        return blackbody(Tstar) * (I * lum);
    }
    static float3 background(float3 d) {
        float3 col = float3(0.0);
        float3 gpole = normalize(float3(0.36, 0.18, 0.92));
        float mu = dot(d, gpole);
        float band = exp(-mu * mu * 16.0);
        float neb  = fbm(d * 5.0 + float3(3.1, 0.0, 1.7));
        float neb2 = fbm(d * 13.0 - float3(7.3, 2.2, 0.0));
        float3 nebCol = mix(float3(0.10, 0.13, 0.30), float3(0.45, 0.27, 0.15), neb2);
        col += band * (0.04 + 0.40 * neb * neb) * nebCol;
        col += float3(0.005, 0.006, 0.011) * (0.35 + 0.65 * neb);
        col += starLayer(d, 23.0, 0.42, 2.0);
        col += starLayer(d, 47.0, 0.38, 1.1);
        col += starLayer(d, 91.0, 0.35, 0.6);
        return col;
    }

    // ------------------------------------------------------------ disk -----
    static float3 diskShade(float r, float chi, float Lz, float sqrtFcam,
                            float time, thread float &alpha) {
        float Om = pow(r, -1.5);                   // Keplerian angular velocity
        float g = sqrt(max(1.0 - 3.0 / r, 0.0))
                / (max(1.0 - Om * Lz, 1e-3) * sqrtFcam);

        // Novikov-Thorne relative temperature, peak-normalized (r = 49/6)
        float xx = max(1.0 - sqrt(R_ISCO / r), 0.0);
        float Trel = pow(xx / (r * r * r), 0.25) * 7.857;

        float chiM = chi - Om * time * 8.0;
        float tex  = fbm(float3(cos(chiM) * 0.9, sin(chiM) * 0.9, r * 1.65) * 2.2);
        float tex2 = fbm(float3(cos(chiM) * 3.0, sin(chiM) * 3.0, r * 0.8)
                         + float3(0.0, 0.0, time * 0.05));
        float pattern = pow(0.35 + 1.30 * tex, 2.2) + 0.35 * tex2;

        float edgeIn  = smoothstep(R_ISCO, R_ISCO + 0.6, r);
        float edgeOut = 1.0 - smoothstep(R_DISK_OUT - 4.5, R_DISK_OUT, r);
        float shape = edgeIn * edgeOut;

        float Tobs = 5900.0 * Trel * g;
        float boost = pow(max(Trel, 0.0), 4.0) * pow(g, 4.0);   // sigma T^4 * g^4

        alpha = clamp((0.40 + 0.60 * tex) * shape * 1.1, 0.0, 0.92);
        return blackbody(Tobs) * (boost * pattern * shape * 2.0);
    }

    // ------------------------------------------------------------ scene ----
    fragment float4 bh_scene(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
        // pixel -> NDC-ish, world up = screen up (Metal position y is top-down)
        float2 px = float2(in.pos.x - 0.5 * U.res.x, 0.5 * U.res.y - in.pos.y)
                  / U.res.y * 2.0;

        // slow orbit around the hole; disk in the world x-y plane, z up
        float az = -2.30 + 0.05 * U.time;
        float el = 0.14, dist = 26.0;
        float3 ro = float3(dist * cos(el) * cos(az), dist * cos(el) * sin(az),
                           dist * sin(el));
        float3 fwd = normalize(-ro);
        float3 right = normalize(cross(fwd, float3(0, 0, 1)));
        float3 up = cross(right, fwd);
        float tanHalf = tan(55.0 * PI / 360.0);
        float3 rd = normalize(fwd + tanHalf * (px.x * right + px.y * up));

        float r0 = length(ro);
        float3 er = ro / r0;
        float3 nv = cross(er, rd);
        float nlen = length(nv);
        if (nlen < 1e-4) {                 // (near-)radial ray: degenerate plane
            rd = normalize(rd + 1e-3 * up);
            nv = cross(er, rd);
            nlen = length(nv);
        }
        float3 nh = nv / nlen;             // orbital-plane normal (~ L direction)
        float3 e2 = cross(nh, er);

        float fcam = 1.0 - 2.0 / r0;
        float sqrtFcam = sqrt(fcam);
        float vr = dot(rd, er);
        float vt = nlen;

        float u = 1.0 / r0;
        float w = -u * sqrtFcam * vr / vt; // du/dphi from the static tetrad
        float b = r0 * vt / sqrtFcam;      // impact parameter (E = 1)
        float Lz = b * nh.z;               // conserved axial angular momentum

        // equatorial crossings: z(phi) ~ sin(phi - phi0), roots phi0 + k*pi
        float A = er.z, B = e2.z;
        float Rz = sqrt(A * A + B * B);
        float phiC = 1e9;
        if (Rz > 1e-4) {
            float phi0 = atan2(-A, B);
            float k = ceil((1e-4 - phi0) / PI);
            phiC = phi0 + k * PI;
        }

        float3 col = float3(0.0);
        float trans = 1.0;
        float phi = 0.0;
        bool escaped = false;

        for (int i = 0; i < MAX_STEPS; i++) {
            float h = (u > 0.15) ? 0.035 : ((u > 0.04) ? 0.07 : 0.12);

            // RK4 on (u, w):  u' = w,  w' = 3u^2 - u
            float u0 = u, w0 = w;
            float k1u = w0,                k1w = 3.0 * u0 * u0 - u0;
            float ua = u0 + 0.5 * h * k1u, wa = w0 + 0.5 * h * k1w;
            float k2u = wa,                k2w = 3.0 * ua * ua - ua;
            float ub = u0 + 0.5 * h * k2u, wb = w0 + 0.5 * h * k2w;
            float k3u = wb,                k3w = 3.0 * ub * ub - ub;
            float uc3 = u0 + h * k3u,      wc3 = w0 + h * k3w;
            float k4u = wc3,               k4w = 3.0 * uc3 * uc3 - uc3;
            float un = u0 + h / 6.0 * (k1u + 2.0 * k2u + 2.0 * k3u + k4u);
            float wn = w0 + h / 6.0 * (k1w + 2.0 * k2w + 2.0 * k3w + k4w);
            float phin = phi + h;

            // handle every equatorial crossing inside this step
            while (phiC <= phin && trans > 0.02) {
                float t = (phiC - phi) / h;
                float h00 = (2.0 * t - 3.0) * t * t + 1.0;
                float h10 = ((t - 2.0) * t + 1.0) * t;
                float h01 = (3.0 - 2.0 * t) * t * t;
                float h11 = (t - 1.0) * t * t;
                float ucr = h00 * u0 + h10 * h * w0 + h01 * un + h11 * h * wn;
                float rc = 1.0 / max(ucr, 1e-6);
                if (rc >= R_ISCO && rc <= R_DISK_OUT) {
                    float3 P = rc * (cos(phiC) * er + sin(phiC) * e2);
                    float chi = atan2(P.y, P.x);
                    float a;
                    float3 dc = diskShade(rc, chi, Lz, sqrtFcam, U.time, a);
                    col += trans * dc;
                    trans *= (1.0 - a);
                }
                phiC += PI;
            }

            u = un; w = wn; phi = phin;
            if (trans <= 0.02) break;
            if (u > U_CAP) break;                        // through the horizon
            if (u < U_ESC && w < 0.0) { escaped = true; break; }
            if (phi > PHI_MAX) break;                    // trapped at photon sphere
        }

        if (escaped && trans > 0.02) {
            // asymptotic direction: dP/dphi ~ -w * rhat + u * that
            float3 rhat = cos(phi) * er + sin(phi) * e2;
            float3 that = -sin(phi) * er + cos(phi) * e2;
            float3 escDir = normalize(-w * rhat + u * that);
            col += trans * background(escDir);
        }
        return float4(col, 1.0);
    }

    // ------------------------------------------------------------- post ----
    fragment float4 bh_bright(VOut in [[stage_in]], constant PostUniforms& U [[buffer(0)]],
                              texture2d<float> scene [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
        float2 uv = in.pos.xy / U.size;
        float3 c = scene.sample(smp, uv).rgb;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        float knee = smoothstep(1.0, 2.4, l);
        return float4(c * knee, 1.0);
    }

    fragment float4 bh_blur(VOut in [[stage_in]], constant PostUniforms& U [[buffer(0)]],
                            texture2d<float> tex [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
        const float gw[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
        float2 uv = in.pos.xy / U.size;
        float3 c = tex.sample(smp, uv).rgb * gw[0];
        for (int i = 1; i < 5; i++) {
            c += tex.sample(smp, uv + U.dir * float(i)).rgb * gw[i];
            c += tex.sample(smp, uv - U.dir * float(i)).rgb * gw[i];
        }
        return float4(c, 1.0);
    }

    static float3 aces(float3 x) {
        return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
    }
    static float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    fragment float4 bh_composite(VOut in [[stage_in]], constant PostUniforms& U [[buffer(0)]],
                                 texture2d<float> scene [[texture(0)]],
                                 texture2d<float> bloom [[texture(1)]],
                                 sampler smp [[sampler(0)]]) {
        const float exposure = 1.0;
        const float bloomStrength = 0.5;
        float2 uv = in.pos.xy / U.size;
        float3 c = scene.sample(smp, uv).rgb + bloomStrength * bloom.sample(smp, uv).rgb;
        c *= exposure;
        c = aces(c);
        c = pow(c, float3(1.0 / 2.2));
        c *= 1.0 - 0.30 * pow(length(uv - 0.5) * 1.30, 3.0);
        c += (hash12(in.pos.xy) - 0.5) / 255.0;
        return float4(c, 1.0);
    }
    """
}
