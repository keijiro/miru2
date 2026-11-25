# miru for macOS

miru is a VR media viewer for macOS built with Swift, Metal, and OXRSys. Arrange local videos, images, and audio in a spatial workspace. The background uses headset passthrough by default. Select the hemisphere icon on a compatible video to show it as a stereoscopic panorama in front of you.

## Build and run

You’ll need macOS 14 or later, Xcode, Git, CMake, and Ninja. The first build fetches and builds OXRSys and the OpenXR Loader in `.build/`.

```sh
./build.sh
./run.sh --library ~/Movies
```

Connect to your Mac from a passthrough-capable OXRSys client. For Wi-Fi streaming, connect both devices to the same local network. On first launch, the workspace is empty. Aim into empty space and hold the trigger for half a second to open the file browser.

The first build creates `.build/runtime/oxrsys-runtime.toml` with `passthrough_enabled` and `app_alpha_blend_passthrough` enabled. If you have a configuration at `~/Library/Application Support/OXRSys/oxrsys-runtime.toml`, OXRSys gives it precedence. Enable both settings there as well.

With no `--library` argument, miru opens `../miru/samples` if it exists and otherwise uses `~/Movies`. Window placement, open files, mute settings, and the active panorama are saved per library. Playback supports the video and audio formats available through AVFoundation. Audio plays through the Mac.

Video and audio resume from their saved positions with their A/B loop points. Miru saves playback history when you return to the browser or quit. If you open the same file in multiple views, the last view closed supplies the saved state. When quitting with several views of the same file still open, the most recently opened view supplies it.

Playback history is stored in `~/Library/Application Support/Miru/Playback.json`. The browser reuses image and video thumbnails from `~/Library/Caches/Miru/Thumbnails/v1/` and trims the cache when it exceeds 256 MiB.

### OXRSys Simulator

```sh
./build.sh --simulator
./run.sh --simulator
```

You can reuse an existing `oxrsys-test` build of the same revision with `MIRU_OXRSYS_BUILD=../oxrsys-test/.build ./build.sh --simulator`.

In the Simulator, select **Search for Server**, then **Connect**. Click the streamed view to focus keyboard input. **F** and **G** act as the left and right triggers, and the arrow keys turn your view. Both controllers follow your head as you move and turn. Tap **Esc** to open a file browser or hold it to recenter the workspace. Passthrough areas appear as a dark background in the Simulator.

## VR controls

| Control | Action |
| --- | --- |
| Hold the trigger in empty space for half a second | Open a file browser |
| Tap the left controller's menu button | Open a file browser in front of you |
| Hold the left controller's menu button for half a second | Recenter the workspace and 180° video to face your current direction |
| Drag a window edge or corner | Move or resize the window |
| Hold the Quest controller’s squeeze button anywhere on a window and drag | Move the window |
| Point at the file list and drag with the trigger, or tilt the pointing controller’s thumbstick up or down | Scroll through files and folders |
| Select **↑ Up** | Return to the parent folder at its previous scroll position |
| Tap a video or audio window | Show or hide the playback panel below the window |
| Drag inside an image or video | Pan the cropped media |
| Select the hemisphere icon in the playback controls | Toggle a 180° equirectangular side-by-side video as the background, with the left eye first |
| Point at the upper-left corner inside a media window or near its edges | Reveal **← Back** and the window handles. Select **← Back** to return to the browser, where **Close** closes the window |

Press `Ctrl+C` in the terminal to end the session.

## Video rendering and performance

AVPlayer outputs 8-bit YCbCr frames in IOSurfaces. miru maps their luma and chroma planes to Metal textures through `CVMetalTextureCache`, shares each frame between the two eyes, and converts it to RGB in the fragment shader. The video path avoids CPU pixel readbacks and intermediate RGB textures. Both eyes are rendered in one command buffer, and OXRSys uses the same Metal queue for streaming. Video output is SDR.

```sh
./run.sh --simulator --open "/path/to/video.mp4" --stress-count 12
```

Repeat `--open` to supply multiple files. `--stress-count` cycles through the supplied videos to open the requested number of muted windows and automatically enables `--metrics`. The metrics report stereo submission rate, video texture updates, and 95th-percentile CPU time, GPU time, and frame interval every two seconds. Use the Simulator’s **RECV** counter and OXRSys encoder statistics to check the downstream stream.
