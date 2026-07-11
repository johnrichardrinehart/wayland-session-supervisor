{ criu, fetchFromGitHub }:
criu.overrideAttrs (old: {
  version = "4.2";
  # Upstream's descriptor generation has a parallel Make dependency race.
  enableParallelBuilding = false;
  postPatch = (old.postPatch or "") + ''
    substituteInPlace images/Makefile \
      --replace-fail 'protoc --proto_path=/usr/include --proto_path=$(obj)/ --c_out=$(obj)/ $<' \
      'protoc --proto_path=$(obj)/ --c_out=$(obj)/ $(DESCRIPTOR_DIR)/descriptor.proto'
  '';
  src = fetchFromGitHub {
    owner = "checkpoint-restore";
    repo = "criu";
    rev = "v4.2";
    hash = "sha256-yZWIpCNTRG0LNGt01BvT3ILl3elzKtCfRKWR0rzJqAU=";
  };
})
