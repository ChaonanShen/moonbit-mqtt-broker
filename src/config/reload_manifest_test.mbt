///|
fn manifest_rejected(contents : String) -> Bool {
  try {
    ignore(parse_reload_manifest(contents))
    false
  } catch {
    _ => true
  }
}

///|
test "reload manifest accepts exact typed bundle roles" {
  let manifest = parse_reload_manifest(
    (
      #|version = 1
      #|[[materials]]
      #|role = "config"
      #|path = "/srv/bundle/config.toml"
      #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      #|[[materials]]
      #|role = "passwords"
      #|path = "/srv/bundle/passwords"
      #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      #|[[materials]]
      #|role = "mqtt_cert"
      #|listener_id = "edge-1"
      #|path = "/srv/bundle/cert.pem"
      #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      #|[[materials]]
      #|role = "mqtt_key"
      #|listener_id = "edge-1"
      #|path = "/srv/bundle/key.pem"
      #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      #|
    ),
  )
  assert_eq(manifest.materials.length(), 4)
  assert_eq(manifest.materials[2].listener_id, Some("edge-1"))
  let tls : Array[ReloadTlsPaths] = [
    {
      listener_id: "edge-1",
      cert_path: "/srv/bundle/cert.pem",
      key_path: "/srv/bundle/key.pem",
    },
  ]
  manifest.validate_effective_paths(
    "/srv/bundle/config.toml",
    Some("/srv/bundle/passwords"),
    None,
    tls,
  )
  let mismatch = try {
    manifest.validate_effective_paths(
      "/srv/bundle/config.toml",
      None,
      None,
      tls,
    )
    false
  } catch {
    _ => true
  }
  assert_true(mismatch)
  let wrong_key = try {
    manifest.validate_effective_paths(
      "/srv/bundle/config.toml",
      Some("/srv/bundle/passwords"),
      None,
      [
        {
          listener_id: "edge-1",
          cert_path: "/srv/bundle/cert.pem",
          key_path: "/srv/bundle/other.pem",
        },
      ],
    )
    false
  } catch {
    _ => true
  }
  assert_true(wrong_key)
  assert_eq(
    manifest.materials[0].sha256,
    Bytes::from_array([
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d,
      0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10,
      0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    ]),
  )
}

///|
test "reload manifest rejects unknown ambiguous and unsafe roles" {
  let config =
    #|version = 1
    #|[[materials]]
    #|role = "config"
    #|path = "/srv/config.toml"
    #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    #|
  assert_true(manifest_rejected("version = 2"))
  assert_true(manifest_rejected(config + "unknown = 1"))
  assert_true(
    manifest_rejected(
      config +
      (
        #|[[materials]]
        #|role = "config"
        #|path = "/srv/other"
        #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #|
      ),
    ),
  )
  assert_true(
    manifest_rejected(
      config.replace_all(old="/srv/config.toml", new="relative.toml"),
    ),
  )
  assert_true(
    manifest_rejected(
      config.replace_all(old="/srv/config.toml", new="/srv/../config.toml"),
    ),
  )
  assert_true(
    manifest_rejected(
      config.replace_all(
        old="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        new="BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
      ),
    ),
  )
  assert_true(
    manifest_rejected(
      config +
      (
        #|[[materials]]
        #|role = "mqtt_key"
        #|path = "/srv/key.pem"
        #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #|
      ),
    ),
  )
  assert_true(
    manifest_rejected(
      config +
      (
        #|[[materials]]
        #|role = "acl"
        #|listener_id = "edge"
        #|path = "/srv/acl"
        #|sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #|
      ),
    ),
  )
}
