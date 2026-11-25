import COpenXR
import Foundation
import simd

typealias Vec2 = SIMD2<Float>
typealias Vec3 = SIMD3<Float>
typealias Vec4 = SIMD4<Float>

struct Ray {
    let origin: Vec3
    let direction: Vec3

    init(_ pose: XrPosef) {
        origin = pose.position.vector
        direction = pose.orientation.rotation.act([0, 0, -1])
    }

    func point(at distance: Float) -> Vec3 { origin + direction * distance }
}

extension XrVector3f {
    var vector: Vec3 { [x, y, z] }
}

extension XrQuaternionf {
    var rotation: simd_quatf { simd_quatf(ix: x, iy: y, iz: z, r: w) }
}

extension XrPosef {
    var matrix: simd_float4x4 {
        var matrix = simd_float4x4(orientation.rotation)
        matrix.columns.3 = Vec4(position.vector, 1)
        return matrix
    }

    var heading: Float {
        let forward = orientation.rotation.act([0, 0, -1])
        return atan2(-forward.x, -forward.z)
    }
}

extension XrFovf {
    var tangents: Vec4 { [tan(angleLeft), tan(angleRight), tan(angleDown), tan(angleUp)] }

    // OpenXR looks down -Z. Metal clip-space depth runs from zero to one.
    var projection: simd_float4x4 {
        let f = tangents
        let near: Float = 0.04, far: Float = 60
        let z = far / (near - far)
        return simd_float4x4(columns: (
            [2 / (f.y - f.x), 0, 0, 0],
            [0, 2 / (f.w - f.z), 0, 0],
            [(f.y + f.x) / (f.y - f.x), (f.w + f.z) / (f.w - f.z), z, -1],
            [0, 0, z * near, 0]
        ))
    }
}

struct Placement: Codable {
    var center: Vec3
    var yaw: Float
    var size: Vec2

    var orientation: simd_quatf { simd_quatf(angle: yaw, axis: [0, 1, 0]) }
    var right: Vec3 { orientation.act([1, 0, 0]) }
    var normal: Vec3 { orientation.act([0, 0, 1]) }

    func hit(_ ray: Ray) -> (uv: Vec2, distance: Float)? {
        let denominator = simd_dot(ray.direction, normal)
        guard abs(denominator) > 0.0001 else { return nil }
        let distance = simd_dot(center - ray.origin, normal) / denominator
        guard distance > 0.04 else { return nil }
        let fromCenter = ray.point(at: distance) - center
        let uv = Vec2(simd_dot(fromCenter, right), -fromCenter.y) / size + Vec2(repeating: 0.5)
        return (uv, distance)
    }

    func model(rect: Rect = .full, offset: Float = 0) -> simd_float4x4 {
        let local = (rect.origin + rect.size * 0.5 - Vec2(repeating: 0.5)) * size
        let worldCenter = center + right * local.x + Vec3(0, -local.y, 0) + normal * offset
        return simd_float4x4(columns: (
            Vec4(right * size.x * rect.size.x, 0), [0, size.y * rect.size.y, 0, 0],
            Vec4(normal, 0), Vec4(worldCenter, 1)
        ))
    }
}

struct Rect: Equatable {
    let origin: Vec2
    let size: Vec2

    init(_ x: Float, _ y: Float, _ width: Float, _ height: Float) {
        origin = [x, y]
        size = [width, height]
    }

    static let full = Rect(0, 0, 1, 1)

    func contains(_ uv: Vec2) -> Bool {
        uv.x >= origin.x && uv.y >= origin.y && uv.x <= origin.x + size.x && uv.y <= origin.y + size.y
    }
}

func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}
