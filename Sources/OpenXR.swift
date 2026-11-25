import COpenXR
import Foundation
import Metal
import os
import QuartzCore

struct MiruError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private func check(_ result: XrResult, _ call: String) throws {
    if result.rawValue < 0 {
        throw MiruError("\(call) failed (XrResult \(result.rawValue))")
    }
}

private let stereo = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
private let identityPose = XrPosef(orientation: XrQuaternionf(x: 0, y: 0, z: 0, w: 1), position: XrVector3f())
private let validPoseFlags = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT

private func copyName<T>(_ name: String, to field: inout T) {
    withUnsafeMutableBytes(of: &field) { destination in
        destination.copyBytes(from: name.utf8.prefix(destination.count - 1))
    }
}

private func xrPath(_ instance: XrInstance, _ string: String) throws -> XrPath {
    var path: XrPath = 0
    try check(xrStringToPath(instance, string, &path), "xrStringToPath(\(string))")
    return path
}

private func makeAction(
    _ set: XrActionSet, _ name: String, _ label: String, _ type: XrActionType, _ paths: [XrPath]
) throws -> XrAction {
    var info = XrActionCreateInfo()
    info.type = XR_TYPE_ACTION_CREATE_INFO
    info.actionType = type
    copyName(name, to: &info.actionName)
    copyName(label, to: &info.localizedActionName)

    var action: XrAction?
    try paths.withUnsafeBufferPointer {
        info.countSubactionPaths = UInt32($0.count)
        info.subactionPaths = $0.baseAddress
        try check(xrCreateAction(set, &info, &action), "xrCreateAction(\(name))")
    }
    guard let action else { throw MiruError("Missing action handle for \(name)") }
    return action
}

struct Hand {
    var pose: XrPosef?
    var trigger: Float = 0
    var stick: Float = 0
}

enum MenuCommand {
    case openBrowser, recenter
}

private struct MenuButton {
    private var ready = false
    private var pressedAt: Double?
    private var command: MenuCommand?

    mutating func update(pressed: Bool?, at time: Double) {
        guard let pressed else {
            self = MenuButton()
            return
        }
        if pressed && ready { pressedAt = time }
        ready = !pressed
        guard let pressedAt else { return }
        let held = time - pressedAt >= 0.5
        if held || !pressed {
            command = held ? .recenter : .openBrowser
            self.pressedAt = nil
        }
    }

    mutating func takeCommand() -> MenuCommand? {
        defer { command = nil }
        return command
    }
}

private func actionValue(_ session: XrSession, _ action: XrAction, _ path: XrPath) throws -> Float {
    var info = XrActionStateGetInfo(type: XR_TYPE_ACTION_STATE_GET_INFO, next: nil, action: action, subactionPath: path)
    var state = XrActionStateFloat()
    state.type = XR_TYPE_ACTION_STATE_FLOAT
    try check(xrGetActionStateFloat(session, &info, &state), "xrGetActionStateFloat")
    return state.isActive != 0 ? state.currentState : 0
}

private func locateHand(
    _ session: XrSession, _ path: XrPath, _ handSpace: XrSpace, _ trigger: XrAction, _ stick: XrAction,
    _ origin: XrSpace, _ time: XrTime
) throws -> Hand {
    var location = XrSpaceLocation(type: XR_TYPE_SPACE_LOCATION, next: nil, locationFlags: 0, pose: identityPose)
    try check(xrLocateSpace(handSpace, origin, time, &location), "xrLocateSpace")
    guard location.locationFlags & validPoseFlags == validPoseFlags else { return Hand() }
    return try Hand(pose: location.pose, trigger: actionValue(session, trigger, path),
                    stick: actionValue(session, stick, path))
}

private final class Eye {
    let swapchain: XrSwapchain
    let rect: XrRect2Di
    let depth: MTLTexture
    private let images: [MTLTexture]

    init(session: XrSession, device: MTLDevice, format: MTLPixelFormat, config: XrViewConfigurationView) throws {
        let width = config.recommendedImageRectWidth
        let height = config.recommendedImageRectHeight
        var info = XrSwapchainCreateInfo(
            type: XR_TYPE_SWAPCHAIN_CREATE_INFO, next: nil, createFlags: 0,
            usageFlags: XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT,
            format: Int64(format.rawValue), sampleCount: 1, width: width, height: height,
            faceCount: 1, arraySize: 1, mipCount: 1
        )
        var handle: XrSwapchain?
        try check(xrCreateSwapchain(session, &info, &handle), "xrCreateSwapchain")
        guard let handle else { throw MiruError("Missing swapchain handle") }

        do {
            var count: UInt32 = 0
            try check(xrEnumerateSwapchainImages(handle, 0, &count, nil), "xrEnumerateSwapchainImages")
            let prototype = XrSwapchainImageMetalKHR(type: XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR, next: nil, texture: nil)
            var metalImages = Array(repeating: prototype, count: Int(count))
            try metalImages.withUnsafeMutableBufferPointer { buffer in
                try check(
                    xrEnumerateSwapchainImages(
                        handle, UInt32(buffer.count), &count,
                        UnsafeMutableRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: XrSwapchainImageBaseHeader.self)
                    ), "xrEnumerateSwapchainImages"
                )
            }
            images = try metalImages.prefix(Int(count)).map { image in
                guard let pointer = image.texture,
                      let texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLTexture
                else { throw MiruError("The runtime returned an invalid Metal swapchain texture") }
                return texture
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: Int(width), height: Int(height), mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw MiruError("Could not create a Metal depth texture")
            }
            depth = texture
            rect = XrRect2Di(offset: XrOffset2Di(), extent: XrExtent2Di(width: Int32(width), height: Int32(height)))
            swapchain = handle
        } catch {
            xrDestroySwapchain(handle)
            throw error
        }
    }

    deinit {
        xrDestroySwapchain(swapchain)
    }

    func withImage(_ render: (MTLTexture) throws -> Void) throws {
        var acquire = XrSwapchainImageAcquireInfo(type: XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO, next: nil)
        var index: UInt32 = 0
        try check(xrAcquireSwapchainImage(swapchain, &acquire, &index), "xrAcquireSwapchainImage")

        var wait = XrSwapchainImageWaitInfo(type: XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, next: nil, timeout: Int64.max)
        try check(xrWaitSwapchainImage(swapchain, &wait), "xrWaitSwapchainImage")

        var release = XrSwapchainImageReleaseInfo(type: XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO, next: nil)
        do {
            guard images.indices.contains(Int(index)) else {
                throw MiruError("The runtime returned an out-of-range swapchain image index")
            }
            try render(images[Int(index)])
        } catch {
            xrReleaseSwapchainImage(swapchain, &release)
            throw error
        }
        try check(xrReleaseSwapchainImage(swapchain, &release), "xrReleaseSwapchainImage")
    }
}

private func createInstance() throws -> XrInstance {
    var instance: XrInstance?
    var info = XrInstanceCreateInfo()
    info.type = XR_TYPE_INSTANCE_CREATE_INFO
    copyName("miru", to: &info.applicationInfo.applicationName)
    info.applicationInfo.apiVersion = (UInt64(1) << 48) | (UInt64(1) << 32) // OpenXR 1.1
    try XR_KHR_METAL_ENABLE_EXTENSION_NAME.withCString { name in
        var extensionName: UnsafePointer<CChar>? = name
        try withUnsafePointer(to: &extensionName) {
            info.enabledExtensionCount = 1
            info.enabledExtensionNames = $0
            try check(xrCreateInstance(&info, &instance), "xrCreateInstance")
        }
    }
    guard let instance else { throw MiruError("Missing instance handle") }
    return instance
}

private func metalDevice(_ instance: XrInstance, _ system: XrSystemId) throws -> MTLDevice {
    var proc: PFN_xrVoidFunction?
    try check(xrGetInstanceProcAddr(instance, "xrGetMetalGraphicsRequirementsKHR", &proc), "xrGetInstanceProcAddr")
    guard let proc else { throw MiruError("Missing xrGetMetalGraphicsRequirementsKHR") }

    let getRequirements = unsafeBitCast(proc, to: PFN_xrGetMetalGraphicsRequirementsKHR.self)
    var requirements = XrGraphicsRequirementsMetalKHR(type: XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR, next: nil, metalDevice: nil)
    try check(getRequirements(instance, system, &requirements), "xrGetMetalGraphicsRequirementsKHR")
    guard let pointer = requirements.metalDevice,
          let device = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLDevice
    else { throw MiruError("Missing runtime Metal device") }
    return device
}

private func makeSession(_ instance: XrInstance, _ system: XrSystemId, _ queue: MTLCommandQueue) throws -> XrSession {
    let binding = XrGraphicsBindingMetalKHR(
        type: XR_TYPE_GRAPHICS_BINDING_METAL_KHR,
        next: nil, commandQueue: Unmanaged.passUnretained(queue as AnyObject).toOpaque()
    )
    var session: XrSession?
    try withUnsafePointer(to: binding) {
        var info = XrSessionCreateInfo(type: XR_TYPE_SESSION_CREATE_INFO, next: $0, createFlags: 0, systemId: system)
        try check(xrCreateSession(instance, &info, &session), "xrCreateSession")
    }
    guard let session else { throw MiruError("Missing session handle") }
    return session
}

private func makeHandSpace(_ session: XrSession, _ pose: XrAction, _ path: XrPath) throws -> XrSpace {
    var info = XrActionSpaceCreateInfo(
        type: XR_TYPE_ACTION_SPACE_CREATE_INFO, next: nil, action: pose, subactionPath: path, poseInActionSpace: identityPose
    )
    var space: XrSpace?
    try check(xrCreateActionSpace(session, &info, &space), "xrCreateActionSpace")
    guard let space else { throw MiruError("Missing hand space handle") }
    return space
}

private func environmentBlendMode(_ instance: XrInstance, _ system: XrSystemId) throws -> XrEnvironmentBlendMode {
    var count: UInt32 = 0
    try check(xrEnumerateEnvironmentBlendModes(instance, system, stereo, 0, &count, nil),
              "xrEnumerateEnvironmentBlendModes")
    var modes = Array(repeating: XR_ENVIRONMENT_BLEND_MODE_OPAQUE, count: Int(count))
    try check(xrEnumerateEnvironmentBlendModes(instance, system, stereo, count, &count, &modes),
              "xrEnumerateEnvironmentBlendModes")
    guard modes.contains(XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND) else {
        throw MiruError("OXRSys alpha blend is unavailable. Set passthrough_enabled and app_alpha_blend_passthrough to true in oxrsys-runtime.toml.")
    }
    return XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND
}

func runMiru(stop: OSAllocatedUnfairLock<Bool>, options: Options) throws {
    let instance = try createInstance()
    defer { xrDestroyInstance(instance) }

    var systemInfo = XrSystemGetInfo(type: XR_TYPE_SYSTEM_GET_INFO, next: nil, formFactor: XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY)
    var system: XrSystemId = 0
    try check(xrGetSystem(instance, &systemInfo, &system), "xrGetSystem")
    let blendMode = try environmentBlendMode(instance, system)
    let device = try metalDevice(instance, system)
    guard let queue = device.makeCommandQueue() else { throw MiruError("Could not create Metal command queue") }

    let handNames = ["/user/hand/left", "/user/hand/right"]
    let paths = try handNames.map { try xrPath(instance, $0) }

    var setInfo = XrActionSetCreateInfo()
    setInfo.type = XR_TYPE_ACTION_SET_CREATE_INFO
    copyName("miru", to: &setInfo.actionSetName)
    copyName("miru", to: &setInfo.localizedActionSetName)
    var setHandle: XrActionSet?
    try check(xrCreateActionSet(instance, &setInfo, &setHandle), "xrCreateActionSet")
    guard let set = setHandle else { throw MiruError("Missing action set handle") }
    defer { xrDestroyActionSet(set) }

    let poseAction = try makeAction(set, "hand_pose", "Controller pose", XR_ACTION_TYPE_POSE_INPUT, paths)
    let triggerAction = try makeAction(set, "trigger", "Select", XR_ACTION_TYPE_FLOAT_INPUT, paths)
    let stickAction = try makeAction(set, "depth", "Window distance", XR_ACTION_TYPE_FLOAT_INPUT, paths)
    let menuAction = try makeAction(set, "menu", "Menu", XR_ACTION_TYPE_BOOLEAN_INPUT, [paths[0]])

    let profile = try xrPath(instance, "/interaction_profiles/oculus/touch_controller")
    var bindings: [XrActionSuggestedBinding] = []
    for hand in handNames {
        bindings.append(XrActionSuggestedBinding(action: poseAction, binding: try xrPath(instance, hand + "/input/aim/pose")))
        let selectPath = options.simulator ? "/input/squeeze/value" : "/input/trigger/value"
        bindings.append(XrActionSuggestedBinding(action: triggerAction, binding: try xrPath(instance, hand + selectPath)))
        bindings.append(XrActionSuggestedBinding(action: stickAction, binding: try xrPath(instance, hand + "/input/thumbstick/y")))
    }
    bindings.append(XrActionSuggestedBinding(action: menuAction, binding: try xrPath(instance, handNames[0] + "/input/menu/click")))
    try bindings.withUnsafeBufferPointer {
        var info = XrInteractionProfileSuggestedBinding(
            type: XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING, next: nil, interactionProfile: profile,
            countSuggestedBindings: UInt32($0.count), suggestedBindings: $0.baseAddress
        )
        try check(xrSuggestInteractionProfileBindings(instance, &info), "xrSuggestInteractionProfileBindings")
    }

    let session = try makeSession(instance, system, queue)
    defer { xrDestroySession(session) }

    try withUnsafePointer(to: setHandle) {
        var info = XrSessionActionSetsAttachInfo(
            type: XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, next: nil, countActionSets: 1, actionSets: $0
        )
        try check(xrAttachSessionActionSets(session, &info), "xrAttachSessionActionSets")
    }

    var spaceInfo = XrReferenceSpaceCreateInfo(
        type: XR_TYPE_REFERENCE_SPACE_CREATE_INFO, next: nil,
        referenceSpaceType: XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR, poseInReferenceSpace: identityPose
    )
    var originHandle: XrSpace?
    try check(xrCreateReferenceSpace(session, &spaceInfo, &originHandle), "xrCreateReferenceSpace")
    guard let origin = originHandle else { throw MiruError("Missing local floor space handle") }
    defer { xrDestroySpace(origin) }

    let leftSpace = try makeHandSpace(session, poseAction, paths[0])
    defer { xrDestroySpace(leftSpace) }
    let rightSpace = try makeHandSpace(session, poseAction, paths[1])
    defer { xrDestroySpace(rightSpace) }

    var count: UInt32 = 0
    try check(xrEnumerateSwapchainFormats(session, 0, &count, nil), "xrEnumerateSwapchainFormats")
    var formats = Array(repeating: Int64(0), count: Int(count))
    try check(xrEnumerateSwapchainFormats(session, count, &count, &formats), "xrEnumerateSwapchainFormats")

    // Prefer the normalized targets used by the SDR stream and its alpha channel.
    let preferredFormats: [MTLPixelFormat] = [.bgra8Unorm, .rgba8Unorm, .bgra8Unorm_srgb, .rgba8Unorm_srgb]
    guard let format = preferredFormats.first(where: { formats.contains(Int64($0.rawValue)) }) else {
        throw MiruError("No compatible Metal color format")
    }

    let viewConfig = XrViewConfigurationView(
        type: XR_TYPE_VIEW_CONFIGURATION_VIEW, next: nil, recommendedImageRectWidth: 0, maxImageRectWidth: 0,
        recommendedImageRectHeight: 0, maxImageRectHeight: 0, recommendedSwapchainSampleCount: 0, maxSwapchainSampleCount: 0
    )
    var configs = [viewConfig, viewConfig]
    try check(
        xrEnumerateViewConfigurationViews(instance, system, stereo, UInt32(configs.count), &count, &configs),
        "xrEnumerateViewConfigurationViews"
    )
    guard count == configs.count else { throw MiruError("Expected two OpenXR views, got \(count)") }
    let eyes = try configs.map { try Eye(session: session, device: device, format: format, config: $0) }
    let shaders = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("Shaders.metal")
    let renderer = try Renderer(device: device, format: format, shaders: shaders)
    let workspace = try Workspace(options: options, device: device)
    let frames = SubmittedFrames()
    defer { frames.drain(); workspace.finish() }
    let metrics = options.metrics ? FrameMetrics() : nil

    print("Metal device: \(device.name). OpenXR alpha blend enabled.")
    print("Media library: \(options.root.path)")
    print(options.simulator ? "Simulator: hold F/G or tap Esc to open a browser. Hold Esc to recenter." :
        "Hold a trigger in empty space for 0.5 seconds to open a browser. Hold the left menu button to recenter.")

    var running = false
    var exitRequested = false
    var firstFrameTime: Double?
    var previousFrameTime: Double?
    var submittedFrames = 0
    var focused = false
    var hadHands = false
    var menuButton = MenuButton()

    while true {
        var event = XrEventDataBuffer()
        event.type = XR_TYPE_EVENT_DATA_BUFFER
        while true {
            let result = xrPollEvent(instance, &event)
            if result == XR_EVENT_UNAVAILABLE { break }
            try check(result, "xrPollEvent")
            switch event.type {
            case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
                throw MiruError("OpenXR instance lost")
            case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED:
                let state = withUnsafePointer(to: &event) {
                    UnsafeRawPointer($0).load(as: XrEventDataSessionStateChanged.self).state
                }
                focused = state == XR_SESSION_STATE_FOCUSED
                if !focused { menuButton = MenuButton() }
                switch state {
                case XR_SESSION_STATE_READY:
                    var begin = XrSessionBeginInfo(type: XR_TYPE_SESSION_BEGIN_INFO, next: nil, primaryViewConfigurationType: stereo)
                    try check(xrBeginSession(session, &begin), "xrBeginSession")
                    running = true
                case XR_SESSION_STATE_STOPPING:
                    try check(xrEndSession(session), "xrEndSession")
                    running = false
                case XR_SESSION_STATE_EXITING:
                    print("Submitted \(submittedFrames) stereo frames.")
                    return
                case XR_SESSION_STATE_LOSS_PENDING:
                    throw MiruError("OpenXR session lost")
                default:
                    break
                }
            default:
                break
            }
            event.type = XR_TYPE_EVENT_DATA_BUFFER
        }

        let timeLimitReached = firstFrameTime.flatMap { start in options.seconds.map { CACurrentMediaTime() - start >= $0 } } ?? false
        if (stop.withLock({ $0 }) || workspace.wantsExit || timeLimitReached) && !exitRequested {
            if !running { return }
            try check(xrRequestExitSession(session), "xrRequestExitSession")
            exitRequested = true
            continue
        }
        guard running else {
            Thread.sleep(forTimeInterval: 0.01)
            continue
        }

        try autoreleasepool {
            var hands = [Hand(), Hand()]
            var menuPressed: Bool?
            var wait = XrFrameWaitInfo(type: XR_TYPE_FRAME_WAIT_INFO, next: nil)
            var frame = XrFrameState()
            frame.type = XR_TYPE_FRAME_STATE
            try check(xrWaitFrame(session, &wait, &frame), "xrWaitFrame")

            if focused && !exitRequested {
                var active = XrActiveActionSet(actionSet: set, subactionPath: 0)
                let syncResult = withUnsafePointer(to: &active) {
                    var info = XrActionsSyncInfo(type: XR_TYPE_ACTIONS_SYNC_INFO, next: nil, countActiveActionSets: 1, activeActionSets: $0)
                    return xrSyncActions(session, &info)
                }
                try check(syncResult, "xrSyncActions")
                if syncResult == XR_SUCCESS {
                    let time = frame.predictedDisplayTime
                    hands[0] = try locateHand(session, paths[0], leftSpace, triggerAction, stickAction, origin, time)
                    hands[1] = try locateHand(session, paths[1], rightSpace, triggerAction, stickAction, origin, time)
                    let bothHands = hands.allSatisfy { $0.pose != nil }
                    if bothHands && !hadHands { print("Tracking both controllers.") }
                    hadHands = bothHands

                    var info = XrActionStateGetInfo(
                        type: XR_TYPE_ACTION_STATE_GET_INFO, next: nil, action: menuAction, subactionPath: paths[0]
                    )
                    var menu = XrActionStateBoolean()
                    menu.type = XR_TYPE_ACTION_STATE_BOOLEAN
                    try check(xrGetActionStateBoolean(session, &info, &menu), "xrGetActionStateBoolean")
                    if menu.isActive != 0 { menuPressed = menu.currentState != 0 }
                }
            }
            menuButton.update(pressed: menuPressed, at: CACurrentMediaTime())

            var begin = XrFrameBeginInfo(type: XR_TYPE_FRAME_BEGIN_INFO, next: nil)
            try check(xrBeginFrame(session, &begin), "xrBeginFrame")

            var end = XrFrameEndInfo(
                type: XR_TYPE_FRAME_END_INFO, next: nil, displayTime: frame.predictedDisplayTime,
                environmentBlendMode: blendMode, layerCount: 0, layers: nil
            )
            var ended = false
            // Complete the begin/end pair even if locating or rendering fails.
            defer { if !ended { xrEndFrame(session, &end) } }

            if frame.shouldRender != 0 && !exitRequested {
                let started = CACurrentMediaTime()
                let period = Double(frame.predictedDisplayPeriod) / 1_000_000_000
                let delta = Float(clamp(started - (previousFrameTime ?? started), 0, 0.05))
                previousFrameTime = started
                let didRender = try renderFrame(
                    session: session, origin: origin, end: end, eyes: eyes, renderer: renderer, queue: queue,
                    workspace: workspace, hands: hands, menu: &menuButton, started: started, delta: delta,
                    frames: frames, metrics: metrics
                )
                if let (result, updates) = didRender {
                    ended = true
                    try check(result, "xrEndFrame")
                    if firstFrameTime == nil { firstFrameTime = started }
                    metrics?.record(start: started, period: period, videoUpdates: updates, workspace: workspace)
                    submittedFrames += 1
                    if submittedFrames == 1 {
                        let sizes = eyes.map { "\($0.rect.extent.width)×\($0.rect.extent.height)" }.joined(separator: " / ")
                        print("Submitted first stereo frame (\(sizes)).")
                    }
                }
            }

            if !ended {
                ended = true
                try check(xrEndFrame(session, &end), "xrEndFrame")
            }
        }
    }
}

private func renderFrame(
    session: XrSession, origin: XrSpace, end: XrFrameEndInfo, eyes: [Eye], renderer: Renderer,
    queue: MTLCommandQueue, workspace: Workspace, hands: [Hand], menu: inout MenuButton, started: Double, delta: Float,
    frames: SubmittedFrames, metrics: FrameMetrics?
) throws -> (XrResult, Int)? {
    var locate = XrViewLocateInfo(
        type: XR_TYPE_VIEW_LOCATE_INFO, next: nil, viewConfigurationType: stereo, displayTime: end.displayTime, space: origin
    )
    var viewState = XrViewState(type: XR_TYPE_VIEW_STATE, next: nil, viewStateFlags: 0)
    let prototype = XrView(type: XR_TYPE_VIEW, next: nil, pose: identityPose, fov: XrFovf())
    var views = [prototype, prototype]
    var count: UInt32 = 0
    try check(xrLocateViews(session, &locate, &viewState, UInt32(views.count), &count, &views), "xrLocateViews")

    let validViews = XR_VIEW_STATE_POSITION_VALID_BIT | XR_VIEW_STATE_ORIENTATION_VALID_BIT
    guard count == views.count, viewState.viewStateFlags & validViews == validViews else { return nil }

    try frames.makeRoom()
    let updated = workspace.update(views: views, hands: hands, menu: menu.takeCommand(), hostTime: started, delta: delta)
    let rendered = renderer.prepare(workspace)
    guard let command = queue.makeCommandBuffer() else { throw MiruError("Could not create a Metal command buffer") }
    try eyes[0].withImage { leftImage in
        try eyes[1].withImage { rightImage in
            try renderer.encode(rendered, into: command, color: leftImage, depth: eyes[0].depth, view: views[0], eye: 0)
            try renderer.encode(rendered, into: command, color: rightImage, depth: eyes[1].depth, view: views[1], eye: 1)
            command.addCompletedHandler { completed in
                withExtendedLifetime(rendered) {}
                metrics?.recordGPU(completed.gpuEndTime - completed.gpuStartTime)
            }
            // OXRSys orders release-time swapchain copies on this same queue.
            command.commit()
            frames.append(command)
        }
    }

    let projectionViews = zip(views, eyes).map { view, eye in
        XrCompositionLayerProjectionView(
            type: XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, next: nil, pose: view.pose, fov: view.fov,
            subImage: XrSwapchainSubImage(swapchain: eye.swapchain, imageRect: eye.rect, imageArrayIndex: 0)
        )
    }
    let result = projectionViews.withUnsafeBufferPointer { buffer in
        let flags: XrCompositionLayerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
        let layer = XrCompositionLayerProjection(
            type: XR_TYPE_COMPOSITION_LAYER_PROJECTION, next: nil, layerFlags: flags, space: origin,
            viewCount: UInt32(buffer.count), views: buffer.baseAddress
        )
        return withUnsafePointer(to: layer) {
            let header: UnsafePointer<XrCompositionLayerBaseHeader>? = UnsafeRawPointer($0)
                .assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)
            return withUnsafePointer(to: header) {
                var info = end
                info.layerCount = 1
                info.layers = $0
                return xrEndFrame(session, &info)
            }
        }
    }
    return (result, updated)
}
