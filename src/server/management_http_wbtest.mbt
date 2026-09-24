///|
priv struct ManagementHttpFixture {
  handler : ManagementHttp
  cache : @management.ObservationCache
  budget : @management.ManagementBudget
  ledger : @budget.Ledger
  rejections : @management.ManagementRejections
  now : Int64
}

///|
fn management_http_fixture(
  scopes? : String = "metrics,read",
  request_burst? : Int = 100,
  connection_burst? : Int = 200,
  request_timeout_ms? : Int = 5000,
  write_timeout_ms? : Int = 2000,
) -> ManagementHttpFixture raise {
  let server_config = ServerConfig::default()
  let state = @router.BrokerState::new(server_config.broker_config())
  let config = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    request_burst~,
    connection_burst~,
    request_timeout_ms~,
    write_timeout_ms~,
  ).unwrap()
  let ledger = state.resource_ledger()
  let budget = @management.ManagementBudget::new(config, ledger).unwrap()
  let cache = @management.ObservationCache::new(budget).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(server_config, state))
  let now = @budget.monotonic_ms()
  let observation = driver.capture_observation(now, 12345L, {
    boot_id: "fixture-boot",
    boot_monotonic_ms: now,
    lifecycle: @management.ServiceLifecycle::Serving,
    mqtt_listener_up: true,
    management_listener_up: true,
    ready_require_snapshot_healthy: false,
  })
  assert_true(cache.publish(observation))
  let tokens = @management.TokenDatabase::parse(
    @utf8.encode(
      "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:" +
      scopes +
      "\n",
    ),
  ).unwrap()
  let rejects = @management.ManagementRejections::new()
  let handler = ManagementHttp::new(
    config, tokens, cache, budget, rejects, "fixture-boot", now,
  ).unwrap()
  { handler, cache, budget, ledger, rejections: rejects, now }
}

///|
fn management_test_head(
  path : String,
  bearer? : String,
  verb? : String = "GET",
) -> @http_transport.HttpRequestHead {
  let headers : Array[@http_transport.HttpHeader] = [
    { name: "host", value: "localhost" },
  ]
  if bearer is Some(value) {
    headers.push({ name: "authorization", value })
  }
  {
    method_name: verb,
    target: path,
    version: "HTTP/1.1",
    headers,
    content_length: None,
  }
}

///|
fn management_test_text(value : Bytes) -> String? {
  Some(@utf8.decode(value)) catch {
    _ => None
  }
}

///|
fn management_test_token() -> String {
  "Bearer spike-token." +
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

///|
test "management health is anonymous while metrics and status are scoped" {
  let f = management_http_fixture()
  let live = management_test_text(
    f.handler.respond(management_test_head("/health/live"), 0, f.now),
  ).unwrap()
  assert_true(live.has_prefix("HTTP/1.1 200 OK"))
  assert_true(live.contains("{\"status\":\"live\"}"))
  let denied = management_test_text(
    f.handler.respond(management_test_head("/metrics"), 0, f.now),
  ).unwrap()
  assert_true(denied.has_prefix("HTTP/1.1 401 Unauthorized"))
  assert_true(denied.contains("WWW-Authenticate: Bearer"))
  assert_false(denied.contains("spike-token"))
  let metric = management_test_text(
    f.handler.respond(
      management_test_head("/metrics", bearer=management_test_token()),
      0,
      f.now,
    ),
  ).unwrap()
  assert_true(metric.has_prefix("HTTP/1.1 200 OK"))
  assert_true(metric.contains("Content-Type: text/plain; version=0.0.4"))
  assert_true(metric.contains("moonbit_mqtt_broker_build_info"))
  let status = management_test_text(
    f.handler.respond(
      management_test_head("/v1/status", bearer=management_test_token()),
      0,
      f.now,
    ),
  ).unwrap()
  assert_true(status.has_prefix("HTTP/1.1 200 OK"))
  assert_true(status.contains("\"api_version\":\"1\""))
  f.cache.close()
  assert_true(f.budget.close())
  assert_eq(f.ledger.occupied(), 0L)
}

///|
test "management role and malformed bearer failures expose no secrets" {
  let f = management_http_fixture(scopes="metrics")
  let forbidden = management_test_text(
    f.handler.respond(
      management_test_head("/v1/status", bearer=management_test_token()),
      0,
      f.now,
    ),
  ).unwrap()
  assert_true(forbidden.has_prefix("HTTP/1.1 403 Forbidden"))
  let altered = "Bearer spike-token." +
    "f123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let bad = management_test_text(
    f.handler.respond(
      management_test_head("/metrics", bearer=altered),
      0,
      f.now,
    ),
  ).unwrap()
  assert_true(bad.has_prefix("HTTP/1.1 401 Unauthorized"))
  assert_false(bad.contains(altered))
  assert_eq(f.rejections.value(@management.RejectedRole), 1L)
  assert_eq(f.rejections.value(@management.RejectedAuth), 1L)
  f.cache.close()
  assert_true(f.budget.close())
}

///|
test "management enforces fixed route method and parser policy" {
  let f = management_http_fixture()
  let unknown = management_test_text(
    f.handler.respond(management_test_head("/unknown"), 0, f.now),
  ).unwrap()
  assert_true(unknown.has_prefix("HTTP/1.1 404 Not Found"))
  let wrong_method = management_test_text(
    f.handler.respond(
      management_test_head("/health/live", verb="POST"),
      0,
      f.now,
    ),
  ).unwrap()
  assert_true(wrong_method.has_prefix("HTTP/1.1 405 Method Not Allowed"))
  assert_true(wrong_method.contains("Allow: GET"))
  let query = management_test_text(
    f.handler.respond(management_test_head("/metrics?token=x"), 0, f.now),
  ).unwrap()
  assert_true(query.has_prefix("HTTP/1.1 400 Bad Request"))
  let suffix = management_test_text(
    f.handler.respond(management_test_head("/health/live"), 3, f.now),
  ).unwrap()
  assert_true(suffix.has_prefix("HTTP/1.1 400 Bad Request"))
  let body = { ..management_test_head("/health/live"), content_length: Some(1) }
  let rejected = management_test_text(f.handler.respond(body, 0, f.now)).unwrap()
  assert_true(rejected.has_prefix("HTTP/1.1 400 Bad Request"))
  f.cache.close()
  assert_true(f.budget.close())
}

///|
test "management accept and request buckets are independent and bounded" {
  let f = management_http_fixture(request_burst=1, connection_burst=1)
  assert_true(f.handler.admit_connection(f.now))
  assert_false(f.handler.admit_connection(f.now))
  let first = management_test_text(
    f.handler.respond(management_test_head("/health/live"), 0, f.now),
  ).unwrap()
  assert_true(first.has_prefix("HTTP/1.1 200 OK"))
  let second = management_test_text(
    f.handler.respond(management_test_head("/health/live"), 0, f.now),
  ).unwrap()
  assert_true(second.has_prefix("HTTP/1.1 429 Too Many Requests"))
  assert_eq(f.rejections.value(@management.RejectedRate), 2L)
  f.cache.close()
  assert_true(f.budget.close())
}

///|
test "management monotonic clock failure is unavailable rather than rate limit" {
  let f = management_http_fixture()
  assert_false(f.handler.admit_connection(-1L))
  let body = management_test_text(
    f.handler.respond(management_test_head("/health/live"), 0, -1L),
  ).unwrap()
  assert_true(body.has_prefix("HTTP/1.1 503 Service Unavailable"))
  assert_eq(f.rejections.value(@management.RejectedStale), 2L)
  assert_eq(f.rejections.value(@management.RejectedRate), 0L)
  f.cache.close()
  assert_true(f.budget.close())
}

///|
async test "management TCP serves one request and closes each socket" {
  let f = management_http_fixture()
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let server = group.spawn(() => {
      for _ in 0..<3 {
        let (connection, _) = listener.accept()
        f.handler.serve_connection(connection)
      }
    })
    let first = @socket.Tcp::connect(listener.addr)
    first.write(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let first_text = management_test_text(first.read_all().binary()).unwrap()
    assert_true(first_text.has_prefix("HTTP/1.1 200 OK"))
    assert_true(first_text.contains("{\"status\":\"live\"}"))
    first.close()
    let second = @socket.Tcp::connect(listener.addr)
    second.write(b"GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let denied = management_test_text(second.read_all().binary()).unwrap()
    assert_true(denied.has_prefix("HTTP/1.1 401 Unauthorized"))
    second.close()
    let third = @socket.Tcp::connect(listener.addr)
    third.write(
      @utf8.encode(
        "GET /v1/status HTTP/1.1\r\nHost: localhost\r\nAuthorization: " +
        management_test_token() +
        "\r\n\r\n",
      ),
    )
    let status = management_test_text(third.read_all().binary()).unwrap()
    assert_true(status.has_prefix("HTTP/1.1 200 OK"))
    assert_true(status.contains("\"api_version\":\"1\""))
    third.close()
    @async.with_timeout(3000, () => server.wait())
  }
  assert_eq(f.budget.active_count(), 0)
  f.cache.close()
  assert_true(f.budget.close())
  assert_eq(f.ledger.occupied(), 0L)
}

///|
async test "malformed management HTTP is rejected over a real socket" {
  let f = management_http_fixture()
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let server = group.spawn(() => {
      let (connection, _) = listener.accept()
      f.handler.serve_connection(connection)
    })
    let client = @socket.Tcp::connect(listener.addr)
    client.write(b"GET /health/live HTTP/1.1\nHost: localhost\n\n")
    let text = management_test_text(client.read_all().binary()).unwrap()
    assert_true(text.has_prefix("HTTP/1.1 400 Bad Request"))
    assert_true(text.contains("\"code\":\"bad_request\""))
    client.close()
    @async.with_timeout(3000, () => server.wait())
  }
  assert_eq(f.budget.active_count(), 0)
  assert_eq(f.rejections.value(@management.RejectedParse), 1L)
  f.cache.close()
  assert_true(f.budget.close())
}

///|
async test "slow management header times out and returns its slot" {
  let f = management_http_fixture(request_timeout_ms=100, write_timeout_ms=100)
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let server = group.spawn(() => {
      let (connection, _) = listener.accept()
      f.handler.serve_connection(connection)
    })
    let client = @socket.Tcp::connect(listener.addr)
    client.write(b"GET /health/live HTTP/1.1\r\nHost: ")
    @async.sleep(200)
    assert_eq(client.read_some(), None)
    client.close()
    @async.with_timeout(3000, () => server.wait())
  }
  assert_eq(f.budget.active_count(), 0)
  assert_eq(f.rejections.value(@management.RejectedDeadline), 1L)
  f.cache.close()
  assert_true(f.budget.close())
  assert_eq(f.ledger.occupied(), 0L)
}

///|
async test "full management request pool closes excess socket" {
  let f = management_http_fixture()
  let held : Array[@management.ManagementRequestLease] = []
  for _ in 0..<16 {
    held.push(f.budget.acquire().unwrap())
  }
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let server = group.spawn(() => {
      let (connection, _) = listener.accept()
      f.handler.serve_connection(connection)
    })
    let client = @socket.Tcp::connect(listener.addr)
    client.write(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let close_result = client.read_some() catch { _ => None }
    assert_eq(close_result, None)
    client.close()
    @async.with_timeout(3000, () => server.wait())
  }
  assert_eq(f.rejections.value(@management.RejectedCapacity), 1L)
  for lease in held {
    assert_true(lease.release())
  }
  f.cache.close()
  assert_true(f.budget.close())
}

///|
async test "config admin sees only boot-scoped reload ETag" {
  let fixture = management_http_fixture(scopes="config_admin")
  let root = @fs.tmpdir(prefix="mqtt-admin-reload-etag-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(
    config_path,
    b"[observability]\nlog_level = \"info\"\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  let (status, output, _) = @process.collect_output("sha256sum", [config_path])
  assert_eq(status, 0)
  let digest = output.text().split(" ").to_array()[0].to_owned()
  let text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    digest +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = @bundle.capture_bundle(manifest_path)
  let effective = bundle.evaluate(config_path, [])
  let handle = GenerationHandle::new(
    ConfigGeneration::initial(
      bundle,
      effective,
      @security.SecurityPolicy::permissive(),
      bundle.policy_fingerprint(effective),
    ),
  )
  fixture.handler.reload_generation = Some(handle)
  let denied = management_test_text(
    fixture.handler.respond_reload_config(
      management_test_head("/v1/config"),
      0,
      fixture.now,
    ),
  ).unwrap()
  assert_true(denied.has_prefix("HTTP/1.1 401 Unauthorized"))
  let response = management_test_text(
    fixture.handler.respond_reload_config(
      management_test_head("/v1/config", bearer=management_test_token()),
      0,
      fixture.now,
    ),
  ).unwrap()
  assert_true(response.has_prefix("HTTP/1.1 200 OK"))
  assert_true(response.contains("ETag: \"fixture-boot:g:0\"\r\n"))
  assert_true(response.contains("\"config_epoch\":\"0\""))
  assert_false(response.contains(config_path))
  assert_false(response.contains("sha256"))
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
  fixture.cache.close()
  ignore(fixture.budget.close())
}
