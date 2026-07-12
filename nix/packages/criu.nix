{
  criu,
  fetchFromGitHub,
  libdrm,
  pkg-config,
}:
criu.overrideAttrs (old: {
  version = "4.2";
  # Upstream's descriptor generation has a parallel Make dependency race.
  enableParallelBuilding = false;
  patches = (old.patches or [ ]) ++ [ ./patches/criu-i915-plugin.patch ];
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkg-config ];
  buildInputs = (old.buildInputs or [ ]) ++ [ libdrm ];
  postPatch = (old.postPatch or "") + ''
    substituteInPlace images/Makefile \
      --replace-fail 'protoc --proto_path=/usr/include --proto_path=$(obj)/ --c_out=$(obj)/ $<' \
      'protoc --proto_path=$(obj)/ --c_out=$(obj)/ $(DESCRIPTOR_DIR)/descriptor.proto'
    substituteInPlace plugins/amdgpu/Makefile \
      --replace-fail 'LIBDRM_INC 		:= -I/usr/include/libdrm' \
      'LIBDRM_INC := $(shell pkg-config --cflags libdrm)'
  '';
  src = fetchFromGitHub {
    owner = "checkpoint-restore";
    repo = "criu";
    rev = "v4.2";
    hash = "sha256-yZWIpCNTRG0LNGt01BvT3ILl3elzKtCfRKWR0rzJqAU=";
  };
})
