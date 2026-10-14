{ lib
, stdenvNoCC
, makeWrapper
, python3
, mayaSrc
, llamaSrc
, engine
, vision
, version
, pinChecked ? true
,
}:

assert pinChecked;

let
  py = python3.withPackages (ps: with ps; [
    numpy
    jinja2
    regex
    pyyaml
    tqdm
    requests
    pillow
    psutil
    textual
  ]);

  share = stdenvNoCC.mkDerivation {
    pname = "maya-share";
    inherit version;
    src = mayaSrc;
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out
      cp -rL ${mayaSrc}/. $out/
      chmod -R u+w $out
      rm -rf $out/.gitattributes $out/.gitignore
      mkdir -p $out/third_party/llama.cpp
      cp -rL ${llamaSrc}/gguf-py $out/third_party/llama.cpp/gguf-py
      cp -rL ${./prefetch.py} $out/prefetch.py
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "maya-serve";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share
    cp -r ${share} $out/share/maya
    chmod -R u+w $out/share/maya
    makeWrapper ${py}/bin/python $out/bin/maya-serve \
      --add-flags "$out/share/maya/serve/server.py"
    makeWrapper ${py}/bin/python $out/bin/maya-chat \
      --add-flags "$out/share/maya/chat.py"
    makeWrapper ${py}/bin/python $out/bin/maya-prefetch \
      --add-flags "$out/share/maya/prefetch.py" \
      --set MAYA_SHARE "$out/share/maya"
    runHook postInstall
  '';

  passthru = {
    inherit engine vision py share;
  };

  meta = {
    description = "Project Maya local inference server (OpenAI/Anthropic-compatible API for GLM-5.3-Flash)";
    homepage = "https://github.com/mw00/project-maya";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "maya-serve";
  };
}
