{ lib
, cmake
, ninja
, git
, python3
, autoAddDriverRunpath
, cudaPackages
, mayaSrc
, llamaSrc
, version
, ggmlPin
, pinChecked ? true
, cudaArch ? "89"
,
}:

assert pinChecked;

cudaPackages.backendStdenv.mkDerivation {
  pname = "maya-vision";
  inherit version;
  src = llamaSrc;
  strictDeps = true;

  nativeBuildInputs = [
    cmake
    ninja
    git
    python3
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [ cudaPackages.cudatoolkit ];

  # The pinned llama.cpp checkout stays untouched upstream: Maya's mtmd addition is applied by
  # tools/vision/glm5next_patch.py (idempotent, anchored on this exact commit), so the build works on
  # a writable copy of it.  The patch script reads its own folder in the Maya tree.
  phases = [ "unpackPhase" "patchPhase" "configurePhase" "buildPhase" "installPhase" ];

  unpackPhase = ''
    runHook preUnpack
    cp -rL ${llamaSrc} "$NIX_BUILD_TOP/llama"
    chmod -R u+w "$NIX_BUILD_TOP/llama"
    runHook postUnpack
  '';

  patchPhase = ''
    runHook prePatch
    python3 ${mayaSrc}/tools/vision/glm5next_patch.py "$NIX_BUILD_TOP/llama"
    runHook postPatch
  '';

  configurePhase = ''
    runHook preConfigure
    cd "$NIX_BUILD_TOP"
    cmake -S ${mayaSrc}/tools/vision -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLAMA_DIR=$NIX_BUILD_TOP/llama \
      -DSTRATA_VISION_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=${cudaArch} \
      -DCMAKE_CUDA_COMPILER=${cudaPackages.cuda_nvcc}/bin/nvcc
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -j "$NIX_BUILD_CORES" -C "$NIX_BUILD_TOP/build" strata-vision
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$NIX_BUILD_TOP/build/bin/strata-vision" $out/bin/strata-vision
    runHook postInstall
  '';

  env = {
    PIN_ASSERT = toString pinChecked;
    GGML_PIN_ASSERT = ggmlPin;
    CUDAToolkit_ROOT = cudaPackages.cudatoolkit;
    CUDAToolkit_INCLUDE_ROOT = cudaPackages.cudatoolkit;
    CUDAToolkit_LIBRARY_ROOT = cudaPackages.cudatoolkit;
  };

  passthru = {
    inherit cudaArch;
  };

  meta = {
    description = "Project Maya image encoder (llama.cpp's mtmd with the GLM-5.3-Flash vision tower, sm_${cudaArch})";
    homepage = "https://github.com/mw00/project-maya";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-vision";
  };
}
