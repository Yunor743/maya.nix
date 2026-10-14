{ lib
, stdenv
, cmake
, ninja
, git
, autoAddDriverRunpath
, cudaPackages
, src
, llamaSrc
, version
, ggmlPin
, pinChecked ? true
, cudaArch ? "89"
,
}:

assert pinChecked;

cudaPackages.backendStdenv.mkDerivation {
  pname = "maya-engine";
  inherit version;
  inherit src;
  strictDeps = true;

  nativeBuildInputs = [
    cmake
    ninja
    git
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [ cudaPackages.cudatoolkit ];

  # Upstream's CMake applies third_party/ggml/mmq-fused-swiglu.patch to a *copy* of the pinned
  # llama.cpp checkout it takes from -DSTRATA_GGML_DIR, and git cannot rewrite files copied out of
  # the read-only store.  So the checkout is handed over as a writable copy in the build tree, and the
  # phases below all work from $NIX_BUILD_TOP so the build directory is never ambiguous.
  configurePhase = ''
    runHook preConfigure
    cp -rL ${llamaSrc} "$NIX_BUILD_TOP/llama-writable"
    chmod -R u+w "$NIX_BUILD_TOP/llama-writable"
    cd "$NIX_BUILD_TOP"
    cmake -S ${src} -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_ENABLE_CUDA=ON \
      -DSTRATA_NATIVE_EXPERTS=ON \
      -DSTRATA_BUILD_TESTS=OFF \
      -DCMAKE_CUDA_ARCHITECTURES=${cudaArch} \
      -DCMAKE_CUDA_COMPILER=${cudaPackages.cuda_nvcc}/bin/nvcc \
      -DSTRATA_GGML_DIR=$NIX_BUILD_TOP/llama-writable \
      -DGGML_NATIVE=OFF \
      -DGGML_AVX=ON \
      -DGGML_AVX2=ON \
      -DGGML_FMA=ON \
      -DGGML_F16C=ON \
      -DGGML_BMI2=ON \
      -DGGML_AVX512=ON
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -j "$NIX_BUILD_CORES" -C "$NIX_BUILD_TOP/build" strata strata-device
    runHook postBuild
  '';

  installPhase = ''
        runHook preInstall
        bin=$(find "$NIX_BUILD_TOP/build" -maxdepth 3 -type f -name strata | head -1)
        dev=$(find "$NIX_BUILD_TOP/build" -maxdepth 3 -type f -name strata-device | head -1)
        if [[ -z "$bin" ]]; then
          echo "strata binary not found under $NIX_BUILD_TOP/build" >&2
          exit 1
        fi
        install -Dm755 "$bin" $out/bin/strata
        [[ -n "$dev" ]] && install -Dm755 "$dev" $out/bin/strata-device
        cat > $out/bin/BUILD.json <<EOF
    {
      "version": "${version}",
      "archs": [${cudaArch}],
      "ptx": false,
      "source": "nix",
      "vision": true
    }
    EOF
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
    description = "Project Maya inference engine for GLM-5.3-Flash (321B MoE) on NVIDIA GPUs (sm_${cudaArch})";
    homepage = "https://github.com/mw00/project-maya";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata";
  };
}
