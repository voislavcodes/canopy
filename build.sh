#!/bin/bash
set -euo pipefail

SDK_PATH=$(xcrun --show-sdk-path)
TARGET="arm64-apple-macosx13.0"
BUILD_DIR=".build/manual"
MODULE_NAME="Canopy"

SOURCES=(
  Sources/Canopy/Models/MusicalTypes.swift
  Sources/Canopy/Models/NoteSequence.swift
  Sources/Canopy/Models/SoundPatch.swift
  Sources/Canopy/Models/Effect.swift
  Sources/Canopy/Models/Node.swift
  Sources/Canopy/Models/NodeTree.swift
  Sources/Canopy/Models/Arrangement.swift
  Sources/Canopy/Models/CanopyProject.swift
  Sources/Canopy/Theme/CanopyColors.swift
  Sources/Canopy/State/ProjectState.swift
  Sources/Canopy/State/CanvasState.swift
  Sources/Canopy/Services/ProjectFactory.swift
  Sources/Canopy/Services/ProjectFileService.swift
  Sources/Canopy/Views/Canvas/CanopyCanvasView.swift
  Sources/Canopy/Views/Node/NodeView.swift
  Sources/Canopy/Views/Node/NodeGlowEffect.swift
  Sources/Canopy/Views/Chrome/ToolbarView.swift
  Sources/Canopy/Views/Chrome/TransportPlaceholder.swift
  Sources/Canopy/App/MainContentView.swift
  Sources/Canopy/App/AppDelegate.swift
  Sources/Canopy/main.swift
)

case "${1:-build}" in
  build)
    echo "Building $MODULE_NAME..."
    mkdir -p "$BUILD_DIR"
    swiftc \
      -sdk "$SDK_PATH" \
      -target "$TARGET" \
      -module-name "$MODULE_NAME" \
      -o "$BUILD_DIR/$MODULE_NAME" \
      "${SOURCES[@]}"
    echo "Built: $BUILD_DIR/$MODULE_NAME"
    ;;
  run)
    "$0" build
    echo "Running $MODULE_NAME..."
    exec "$BUILD_DIR/$MODULE_NAME"
    ;;
  test)
    echo "Building module for testing..."
    mkdir -p "$BUILD_DIR"
    # Build the module (library) with testability
    swiftc \
      -sdk "$SDK_PATH" \
      -target "$TARGET" \
      -module-name "$MODULE_NAME" \
      -emit-module -emit-module-path "$BUILD_DIR/" \
      -emit-library -o "$BUILD_DIR/lib${MODULE_NAME}.dylib" \
      -enable-testing \
      "${SOURCES[@]}"
    echo "Building tests..."
    TEST_SOURCES=(
      Tests/CanopyTests/ModelCodableTests.swift
      Tests/CanopyTests/ProjectFileServiceTests.swift
    )
    swiftc \
      -sdk "$SDK_PATH" \
      -target "$TARGET" \
      -module-name CanopyTests \
      -I "$BUILD_DIR" \
      -L "$BUILD_DIR" \
      -lCanopy \
      -Xlinker -rpath -Xlinker "$BUILD_DIR" \
      -o "$BUILD_DIR/CanopyTests" \
      "${TEST_SOURCES[@]}"
    echo "Running tests..."
    "$BUILD_DIR/CanopyTests"
    ;;
  clean)
    rm -rf "$BUILD_DIR"
    echo "Cleaned."
    ;;
  *)
    echo "Usage: $0 {build|run|test|clean}"
    exit 1
    ;;
esac
