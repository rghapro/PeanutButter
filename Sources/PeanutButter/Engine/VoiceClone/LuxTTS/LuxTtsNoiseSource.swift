import Foundation

/// (1 × 1 × 256) plus `numSteps - 1` aux vectors (each 1 × 1 × 256). Since the
/// fused graph is deterministic in the noise inputs, we can use any
/// reproducible Gaussian source — we don't need bit-for-bit parity with
/// torch's RNG (the upstream parity guarantee is between `--no-fused` and
/// fused for *the same* seed; fused vs Swift sampler gives equivalent-quality
/// audio with different fine detail).
public struct LuxTtsNoiseSource: Sendable {

    private var state: UInt64

    public init(seed: UInt64) {
        // SplitMix64 init from a non-zero seed.
        self.state = seed == 0 ? 0xdead_beef_cafe_babe : seed
    }

    /// Draw the next double-precision uniform in (0, 1].
    private mutating func nextUniform() -> Double {
        // SplitMix64 step.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        // Map to (0, 1] (avoid log(0) downstream).
        let u = Double(z >> 11) / Double(1 << 53)
        return u <= 0 ? .leastNormalMagnitude : u
    }

    /// Draw a single Gaussian sample N(0, 1).
    public mutating func nextGaussian() -> Float {
        let u1 = nextUniform()
        let u2 = nextUniform()
        let mag = sqrt(-2.0 * log(u1))
        return Float(mag * cos(2.0 * .pi * u2))
    }

    /// Fill `count` Float32 Gaussians.
    public mutating func nextGaussianArray(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = nextGaussian() }
        return out
    }
}
