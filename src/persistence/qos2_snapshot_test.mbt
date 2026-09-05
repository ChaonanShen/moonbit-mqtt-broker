///|
/// Fixed bytes are independent of the MoonBit writer; preserve these across migrations.
test "nonempty disk v1 and v2 goldens migrate qos1 without inventing qos2 state" {
  {
    let golden = b"\x4d\x42\x4d\x51\x54\x54\x30\x31\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x4d\xfb\xec\x92\xec\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x06\x6c\x65\x67\x61\x63\x79\x00\x2b\x00\x00\x00\x01\x00\x00\x00\x01\x23\x01\x00\x00\x00\x01\x00\x2a\x00\x00\x00\x01\x61\x00\x00\x00\x01\x78\x00\x00\x00\x00\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x78\x00\x00\x00\x00\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x72\x01"
    let decoded = decode_snapshot(golden, codec_limits()).unwrap()
    assert_eq(encode_snapshot(decoded), Ok(golden))
    let state = @router.BrokerState::from_snapshot(
      persistence_broker_config(),
      decoded,
    ).unwrap()
    let current = state.export_snapshot()
    assert_eq(current.version, 3)
    assert_eq(current.sessions[0].inbound_qos2, [])
    assert_eq(current.sessions[0].inflight[0].phase, 1)
    assert_eq(current.sessions[0].inflight[0].message.unwrap().qos, 1)
    assert_eq(current.sessions[0].pending[0].qos, 1)
    assert_eq(current.sessions[0].next_packet_id, 43)
    assert_eq(current.sessions[0].owner_principal, "legacy-anonymous")
    assert_eq(current.sessions[0].detached_at_ms, 0L)
  }
  let golden = b"\x4d\x42\x4d\x51\x54\x54\x30\x31\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x62\xb6\x4e\x71\xd0\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x06\x6c\x65\x67\x61\x63\x79\x00\x00\x00\x0a\x75\x73\x65\x72\x3a\x61\x6c\x69\x63\x65\x00\x00\x00\x03\x31\x32\x33\x00\x2b\x00\x00\x00\x01\x00\x00\x00\x01\x23\x01\x00\x00\x00\x01\x00\x2a\x00\x00\x00\x01\x61\x00\x00\x00\x01\x78\x00\x00\x00\x00\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x78\x00\x00\x00\x00\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x72\x01"
  let decoded = decode_snapshot(golden, codec_limits()).unwrap()
  assert_eq(encode_snapshot(decoded), Ok(golden))
  let state = @router.BrokerState::from_snapshot(
    persistence_broker_config(),
    decoded,
  ).unwrap()
  let current = state.export_snapshot()
  assert_eq(current.version, 3)
  assert_eq(current.sessions[0].inbound_qos2, [])
  assert_eq(current.sessions[0].inflight[0].phase, 1)
  assert_eq(current.sessions[0].inflight[0].message.unwrap().qos, 1)
  assert_eq(current.sessions[0].pending[0].qos, 1)
  assert_eq(current.sessions[0].next_packet_id, 43)
  assert_eq(current.sessions[0].owner_principal, "user:alice")
  assert_eq(current.sessions[0].detached_at_ms, 123L)
}

///|
fn qos2_golden() -> Bytes {
  b"\x4d\x42\x4d\x51\x54\x54\x30\x31\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x77\xd0\x5f\x4a\x56\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00\x01\x63\x00\x00\x00\x09\x61\x6e\x6f\x6e\x79\x6d\x6f\x75\x73\x00\x00\x00\x01\x30\x00\x04\x00\x00\x00\x01\x00\x00\x00\x01\x23\x02\x00\x00\x00\x02\x00\x01\xff\xff\x00\x00\x00\x03\x00\x01\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x01\x00\x01\x00\x02\x02\x00\x00\x00\x01\x61\x00\x00\x00\x01\x02\x00\x02\x00\x03\x03\x00\x00\x00\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x70\x01\x02\x00\x00\x00\x01\x00\x00\x00\x01\x61\x00\x00\x00\x01\x72\x02"
}

///|
test "disk v3 golden preserves inbound and all outbound phases without pubcomp payload" {
  let golden = qos2_golden()
  let decoded = decode_snapshot(golden, codec_limits()).unwrap()
  assert_eq(encode_snapshot(decoded), Ok(golden))
  assert_eq(decoded.sessions[0].inbound_qos2, [1, 65535])
  assert_eq(decoded.sessions[0].inflight.map(item => item.phase), [1, 2, 3])
  assert_eq(decoded.sessions[0].inflight[2].message, None)
  let state = @router.BrokerState::from_snapshot(
    persistence_broker_config(),
    decoded,
  ).unwrap()
  assert_eq(state.export_snapshot(), decoded)
  let client = @session.ClientId::new("c").unwrap()
  let actions = state.apply(AttachSession(client)).unwrap()
  assert_eq(actions.length(), 5)
  assert_true(actions[3] is SendPubrel(_))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "disk v3 rejects unknown phases mismatch duplicate ids and legacy downgrades" {
  let golden = qos2_golden()
  let invalid_phase = refresh_payload_crc(replace_byte(golden, 81, 4))
  assert_true(
    decode_snapshot(invalid_phase, codec_limits()) is Err(InvalidValue(..)),
  )
  let decoded = decode_snapshot(golden, codec_limits()).unwrap()
  let saved = decoded.sessions[0]
  let contradictory = { ..saved.inflight[0], phase: 2 }
  let broken = { ..decoded, sessions: [{ ..saved, inflight: [contradictory] }] }
  assert_true(encode_snapshot(broken) is Err(InvalidValue(..)))
  assert_true(
    @router.BrokerState::from_snapshot(persistence_broker_config(), broken)
    is Err(_),
  )
  let duplicate_inbound = {
    ..decoded,
    sessions: [{ ..saved, inbound_qos2: [1, 1] }],
  }
  assert_true(
    @router.BrokerState::from_snapshot(
      persistence_broker_config(),
      duplicate_inbound,
    )
    is Err(_),
  )
  assert_true(
    decode_snapshot(encode_snapshot(duplicate_inbound).unwrap(), codec_limits())
    is Err(InvalidValue(..)),
  )
  for version in [1, 2] {
    assert_true(
      encode_snapshot({ ..decoded, version, }) is Err(InvalidValue(..)),
    )
    assert_true(
      @router.BrokerState::from_snapshot(persistence_broker_config(), {
        ..decoded,
        version,
      })
      is Err(_),
    )
  }
  for end in 0..<golden.length() {
    assert_true(
      decode_snapshot(
        Bytes::from_array(golden.to_array()[:end].to_owned()),
        codec_limits(),
      )
      is Err(_),
    )
  }
}
