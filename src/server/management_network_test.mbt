///|
async test "MQTT and management listeners share one driver and shut down" {
  @async.with_task_group() <| group => {
    let broker = @router.BrokerConfig::new(8, 64, 8).unwrap()
    let config = ServerConfig::new(8, 1024, 2048, 8, 64, 1000, 10, broker).unwrap()
    let state = @router.BrokerState::new(broker)
    let mqtt_listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let admin_listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer mqtt_listener.close()
    defer admin_listener.close()
    let management_config = @management.ManagementConfig::new(
      enabled=true,
      token_file="/fixture/tokens",
      snapshot_interval_ms=100,
      snapshot_max_age_ms=500,
      request_timeout_ms=1000,
      write_timeout_ms=500,
    ).unwrap()
    let tokens = @management.TokenDatabase::parse(
      @utf8.encode(
        "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:metrics,read\n",
      ),
    ).unwrap()
    let management = ManagementRuntime::new(
      admin_listener,
      { config: management_config, tokens },
      state.resource_ledger(),
    ).unwrap()
    defer management.close()
    let stop = Ref(false)
    let task = group.spawn(() => {
      serve(
        mqtt_listener,
        config,
        state,
        shutdown_requested=() => stop.val,
        management~,
      )
    })
    let mqtt = @socket.Tcp::connect(mqtt_listener.addr)
    let admin = @socket.Tcp::connect(admin_listener.addr)
    defer mqtt.close()
    defer admin.close()
    let connect = @protocol.encode_packet(
      Connect({
        client_id: "two-listener-test",
        username: None,
        password: None,
        keep_alive: 10,
        clean_session: true,
        will: None,
      }),
    ).unwrap()
    mqtt.write(connect)
    assert_eq(mqtt.read_exactly(4), b"\x20\x02\x00\x00")
    let initial_observation = management.cache.captured_at().unwrap()
    let mut refreshed = false
    for _ in 0..<100 {
      if management.cache.captured_at().unwrap() > initial_observation {
        refreshed = true
        break
      }
      @async.sleep(5)
    }
    assert_true(refreshed)
    admin.write(b"GET /health/ready HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let health = @utf8.decode(admin.read_all().binary()) catch {
      _ => fail("health was not UTF-8")
    }
    assert_true(health.has_prefix("HTTP/1.1 200 OK"))
    let status_client = @socket.Tcp::connect(admin_listener.addr)
    status_client.write(
      @utf8.encode(
        "GET /v1/status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer spike-token." +
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" +
        "\r\n\r\n",
      ),
    )
    let status = @utf8.decode(status_client.read_all().binary()) catch {
      _ => fail("status was not UTF-8")
    }
    status_client.close()
    assert_true(status.has_prefix("HTTP/1.1 200 OK"))
    assert_true(status.contains("\"sessions\":\"1\""))
    stop.val = true
    @async.with_timeout(3000, () => task.wait())
    management.close()
    assert_true(management.budget.is_closed())
  }
}
