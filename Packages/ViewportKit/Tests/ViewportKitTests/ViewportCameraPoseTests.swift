import Testing
@testable import ViewportKit

struct ViewportCameraPoseTests {

    @Test func capturesOrbitCameraState() {
        var camera = OrbitCamera()
        camera.target = SIMD3(1.5, -2, 3)
        camera.distance = 7.25
        camera.azimuth = 0.9
        camera.elevation = -0.3
        let pose = ViewportCameraPose(camera: camera)
        #expect(pose.target == SIMD3(1.5, -2, 3))
        #expect(pose.distance == 7.25)
        #expect(pose.azimuth == 0.9)
        #expect(pose.elevation == -0.3)
    }

    @Test func defaultCameraCapture() {
        let camera = OrbitCamera()
        let pose = ViewportCameraPose(camera: camera)
        #expect(pose.target == camera.target)
        #expect(pose.distance == camera.distance)
    }
}
