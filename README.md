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

### Quick Start

An automated setup script is included:

```sh
./setup_ios.sh
```

### Manual Build

1. **Clone with LFS**

   ```sh
   GIT_LFS_SKIP_SMUDGE=1 git clone git@github.com:salmazov/blender-ios.git
   cd blender-ios
   git checkout ios-new
   git lfs pull
   ```

2. **Fetch prebuilt libraries**

   ```sh
   git submodule update --init lib/ios_arm64
   git submodule update --init lib/macos_arm64
   ```

3. **Configure with CMake**

   ```sh
   IOS_LIBDIR="$(pwd)/lib/ios_arm64"
   IOS_DEV_ROOT="$IOS_LIBDIR/iossdk"

   cmake -G Xcode -S . -B build_ios \
     -DCMAKE_SYSTEM_NAME=iOS \
     -DCMAKE_OSX_ARCHITECTURES=arm64 \
     -DWITH_APPLE_CROSSPLATFORM=ON \
     -DAPPLE_TARGET_DEVICE=ios \
     -DCMAKE_FIND_ROOT_PATH="$IOS_DEV_ROOT;$(dirname "$IOS_DEV_ROOT");$IOS_LIBDIR" \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
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

5. **Deploy** — connect your iPad and run from Xcode (requires a valid signing identity).


License
-------

Blender as a whole is licensed under the GNU General Public License, Version 3.
Individual files may have a different but compatible license.

See [blender.org/about/license](https://www.blender.org/about/license) for details.
