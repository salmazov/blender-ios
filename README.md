<!--
Keep this document short & concise,
linking to external resources instead of including content in-line.
See 'release/text/readme.html' for the end user read-me.
-->

Blender
=======

Blender is the free and open source 3D creation suite.
It supports the entirety of the 3D pipeline—modeling, rigging, animation, simulation, rendering, compositing,
motion tracking and video editing.

![Blender screenshot](https://code.blender.org/wp-content/uploads/2018/12/springrg.jpg "Blender screenshot")

Project Pages
-------------

- [Main Website](https://www.blender.org)
- [Reference Manual](https://docs.blender.org/manual/en/latest/index.html)
- [User Community](https://www.blender.org/community/)

Development
-----------

- [Build Instructions](https://developer.blender.org/docs/handbook/building_blender/)
- [Code Review & Bug Tracker](https://projects.blender.org)
- [Developer Forum](https://devtalk.blender.org)
- [Developer Documentation](https://developer.blender.org/docs/)


Building for iPad (iOS)
-----------------------

### Prerequisites

- macOS with Apple Silicon (arm64)
- Xcode 26+ with iOS SDK
- CMake 3.28+
- Git LFS
- An iPad running **iPadOS 26 or newer** (the minimum deployment target)
- An Apple ID for code signing (a free one works, with the limits noted in step 5)

Expect roughly 20 GB of disk space (repository, prebuilt libraries and one Xcode
build directory) and a first build of 15-30 minutes.

### Quick Start

An automated setup script checks dependencies, fetches the prebuilt libraries and
configures the Xcode project:

```sh
./setup_ios.sh
```

It does not configure code signing, so you still need step 5 below to get the app
onto a device. If the script fails, work through the manual steps instead.

### Manual Build

1. **Clone and fetch LFS content**

   ```sh
   GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/salmazov/blender-ios.git
   cd blender-ios
   git checkout ios-new
   git lfs pull
   ```

   LFS objects are served from `projects.blender.org` rather than GitHub, which
   the committed `.lfsconfig` handles automatically. Verify it worked — this
   should report `PNG image data`, not `ASCII text`:

   ```sh
   file release/ios/Blender.app/Assets.xcassets/AppIcon.appiconset/blender_icon_1024x1024.png
   ```

   If it still says `ASCII text` the files are unresolved LFS pointers, and the
   build will later fail with
   `The app icon set "AppIcon" did not have any applicable content`.

2. **Fetch prebuilt libraries**

   These submodules are configured with `update = none`, so `--checkout` is required to force the initial checkout:

   ```sh
   git submodule update --init --checkout lib/ios_arm64
   git submodule update --init --checkout lib/macos_arm64
   ```

3. **Configure with CMake**

   ```sh
   IOS_LIBDIR="$(pwd)/lib/ios_arm64"
   IOS_SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
   IOS_DEV_ROOT="$(dirname "$IOS_SDK_ROOT")"

   cmake -G Xcode -S . -B build_ios \
     -DCMAKE_SYSTEM_NAME=iOS \
     -DWITH_APPLE_CROSSPLATFORM=ON \
     -DAPPLE_TARGET_DEVICE=ios \
     -DCMAKE_FIND_ROOT_PATH="$IOS_DEV_ROOT;$(dirname "$IOS_DEV_ROOT");$IOS_LIBDIR"
   ```

4. **Build with Xcode**

   Open `build_ios/Blender.xcodeproj` in Xcode, select your iPad as the destination, and build the **blender** scheme.

   Or build from the command line:

   ```sh
   cd build_ios
   xcodebuild -project Blender.xcodeproj -scheme blender \
     -configuration Release -sdk iphoneos \
     -jobs $(sysctl -n hw.ncpu) build
   ```

5. **Sign and install on the iPad**

   Signing is the step people most often get stuck on. With a **free** Apple ID
   you must use a bundle identifier of your own — the default
   (`org.blenderfoundation.blender.dev`) belongs to someone else and automatic
   signing will fail. Pass your own when configuring:

   ```sh
   cmake -G Xcode -S . -B build_ios \
     -DBLENDER_BUNDLE_IDENTIFIER=com.yourname.blender \
     ...
   ```

   The development team is auto-detected from your keychain. If you have more
   than one, set it explicitly with `-DBLENDER_DEVELOPMENT_TEAM=XXXXXXXXXX`
   (the 10-character Team ID from the Apple Developer portal).

   Then, in Xcode:

   1. Sign in with your Apple ID under **Settings → Accounts**.
   2. Select the **blender** target → **Signing & Capabilities** → tick
      *Automatically manage signing* and pick your team.
   3. Connect the iPad, choose it as the run destination, and press Run.
   4. The first launch is blocked by iOS. On the iPad, go to
      **Settings → General → VPN & Device Management**, tap your developer
      profile and trust it, then launch the app again.

   Free Apple ID limits worth knowing:

   - The app stops launching after **7 days** and must be rebuilt from Xcode.
   - Only **3** development-signed apps can be installed per device. If you see
     *"maximum number of installed apps using a free developer profile"*, delete
     another sideloaded app first.

   A paid Apple Developer account removes both limits.

### Faster iteration (Ninja + ccache)

The Xcode generator is slow to configure and re-runs thousands of codegen script
phases on every build. For a quick compile/error-check loop, use a separate Ninja
build directory and keep the Xcode project purely for debugging and device deploy:

```sh
brew install ccache

IOS_LIBDIR="$(pwd)/lib/ios_arm64"
IOS_SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_DEV_ROOT="$(dirname "$IOS_SDK_ROOT")"

cmake -G Ninja -S . -B build_ios_ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_BUILD_TYPE=Debug \
  -DWITH_APPLE_CROSSPLATFORM=ON \
  -DAPPLE_TARGET_DEVICE=ios \
  -DWITH_COMPILER_CCACHE=ON \
  -DCMAKE_FIND_ROOT_PATH="$IOS_DEV_ROOT;$(dirname "$IOS_DEV_ROOT");$IOS_LIBDIR"

ninja -C build_ios_ninja blender
```

Rough numbers on an M-series laptop: configure 28s (vs ~140s for Xcode), null
rebuild ~20s, and a single-file change ~60s including relink and bundling.

On the first Ninja build the cross-compiled host tools are built into a separate
directory, so run `ninja -C build_ios_ninja blender_cross_tools_compile` first if
the build reports a missing `shader_tool`.

Ninja also catches availability bugs that the Xcode generator hides, because it
honours the configured deployment target instead of defaulting to the SDK version.

### Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Object does not exist on the server: [404]` during `git lfs pull` | LFS is pointing at GitHub, which does not host these objects. Make sure you are on a checkout that contains `.lfsconfig`, then re-run `git lfs pull`. |
| Build fails with `The app icon set "AppIcon" did not have any applicable content` | LFS content was never fetched, so the icons are still pointer files. Run `git lfs pull && git lfs checkout`. |
| `Skipping submodule 'lib/ios_arm64'`, or missing headers and libraries | The submodules set `update = none`; you need `git submodule update --init --checkout lib/ios_arm64`. |
| `Could not find a package configuration file provided by "draco"` | Stale CMake cache from an older checkout. Delete `build_ios` and configure again. |
| `unable to install ... maximum number of installed apps using a free developer profile` | Delete another sideloaded app from the iPad, or use a paid developer account. |
| App installs but will not open | Trust the developer profile under **Settings → General → VPN & Device Management** on the iPad. |
| Ninja build stops with a missing `shader_tool` | Build the host tools first: `ninja -C build_ios_ninja blender_cross_tools_compile`. |

### Known limitations

- `draco` and `meshoptimizer` (glTF mesh/point-cloud compression) have no prebuilt iOS libraries yet and are automatically disabled during configure.


License
-------

Blender as a whole is licensed under the GNU General Public License, Version 3.
Individual files may have a different but compatible license.

See [blender.org/about/license](https://www.blender.org/about/license) for details.
