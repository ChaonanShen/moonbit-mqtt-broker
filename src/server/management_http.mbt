///|
pub(all) enum ManagementRoute {
  RouteLive
  RouteReady
  RouteMetrics
  RouteStatus
} derive(Eq)

///|
/// One service-wide request/accept limiter, independent of MQTT rate switches.
pub struct ManagementHttp {
  config : @management.ManagementConfig
  tokens : @management.TokenDatabase
  cache : @management.ObservationCache
  budget : @management.ManagementBudget
  rejections : @management.ManagementRejections
  connection_bucket : @budget.Bucket
  request_bucket : @budget.Bucket
  boot_id : String
  mut next_request_id : Int64
}

///|
pub fn ManagementHttp::new(
  config : @management.ManagementConfig,
  tokens : @management.TokenDatabase,
  cache : @management.ObservationCache,
  budget : @management.ManagementBudget,
  rejections : @management.ManagementRejections,
  boot_id : String,
  now_monotonic_ms : Int64,
) -> Result[ManagementHttp, @budget.BudgetError] {
  if !config.enabled() {
    return Err(@budget.InvalidConfiguration)
  }
  let connection_bucket = match
    @budget.Bucket::new(
      config.connection_rate().to_int64(),
      config.connection_burst().to_int64(),
      now_monotonic_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let request_bucket = match
    @budget.Bucket::new(
      config.request_rate().to_int64(),
      config.request_burst().to_int64(),
      now_monotonic_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    config,
    tokens,
    cache,
    budget,
    rejections,
    connection_bucket,
    request_bucket,
    boot_id,
    next_request_id: 1L,
  })
}

///|
fn ManagementHttp::request_id(self : ManagementHttp) -> String? {
  if self.next_request_id <= 0L || self.next_request_id == 9223372036854775807L {
    return None
  }
  let id = self.boot_id + "." + self.next_request_id.to_string()
  self.next_request_id += 1L
  Some(id)
}

///|
pub fn ManagementHttp::admit_connection(
  self : ManagementHttp,
  now_monotonic_ms : Int64,
) -> Bool {
  if now_monotonic_ms < 0L {
    self.rejections.record(@management.RejectedStale)
    return false
  }
  if @budget.admit([(self.connection_bucket, 1L)], now_monotonic_ms) is Err(_) {
    self.rejections.record(@management.RejectedRate)
    false
  } else {
    true
  }
}

///|
fn management_error_body(code : String, request_id : String) -> Bytes {
  let detail : Map[String, String] = Map([
    ("code", code),
    ("message", code),
    ("request_id", request_id),
  ])
  let body : Map[String, Json] = Map([("error", @json.to_json(detail))])
  @utf8.encode(@json.to_json(body).stringify())
}

///|
fn ManagementHttp::encode(
  self : ManagementHttp,
  status : @http_transport.HttpStatus,
  body : Bytes,
  body_type : @http_transport.HttpBodyType,
  allow? : @http_transport.HttpAllow,
) -> Bytes {
  match
    @http_transport.encode_response(
      status,
      body_type,
      body,
      self.config.max_response_bytes(),
      allow?,
    ) {
    Ok(value) => value
    Err(_) =>
      @http_transport.encode_response(
        @http_transport.ServiceUnavailable,
        @http_transport.JsonBody,
        b"{\"error\":{\"code\":\"unavailable\"}}",
        self.config.max_response_bytes(),
      ).unwrap()
  }
}

///|
fn ManagementHttp::reject(
  self : ManagementHttp,
  status : @http_transport.HttpStatus,
  code : String,
  request_id : String,
  reason : @management.ManagementRejectReason,
  allow? : @http_transport.HttpAllow,
) -> Bytes {
  self.rejections.record(reason)
  self.encode(
    status,
    management_error_body(code, request_id),
    @http_transport.JsonBody,
    allow?,
  )
}

///|
fn management_header(
  head : @http_transport.HttpRequestHead,
  name : String,
) -> String? {
  for header in head.headers {
    if header.name == name {
      return Some(header.value)
    }
  }
  None
}

///|
fn management_bearer(value : String) -> String? {
  if value.length() < 8 || value[6].to_int() != 32 {
    return None
  }
  let prefix = value[:6].to_owned()
  let letters = "bearer"
  for index in 0..<6 {
    let unit = prefix[index].to_int()
    let lowered = if unit >= 65 && unit <= 90 { unit + 32 } else { unit }
    if lowered != letters[index].to_int() {
      return None
    }
  }
  Some(value[7:].to_owned())
}

///|
/// Route on already parsed, bounded head data. No broker state or message
/// payload can be reached from this function.
pub fn ManagementHttp::respond(
  self : ManagementHttp,
  head : @http_transport.HttpRequestHead,
  same_read_suffix_bytes : Int,
  now_monotonic_ms : Int64,
) -> Bytes {
  let request_id = match self.request_id() {
    Some(value) => value
    None =>
      return self.encode(
        @http_transport.ServiceUnavailable,
        b"{\"error\":{\"code\":\"id_exhausted\"}}",
        @http_transport.JsonBody,
      )
  }
  let target = head.target
  if target.contains("?") ||
    target.contains("%") ||
    target.contains("#") ||
    same_read_suffix_bytes != 0 ||
    (head.content_length is Some(length) && length != 0) {
    return self.reject(
      @http_transport.BadRequest,
      "bad_request",
      request_id,
      @management.RejectedParse,
    )
  }
  for forbidden in ["transfer-encoding", "upgrade", "expect"] {
    if management_header(head, forbidden) is Some(_) {
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
    }
  }
  let route = match target {
    "/health/live" => Some(RouteLive)
    "/health/ready" => Some(RouteReady)
    "/metrics" => Some(RouteMetrics)
    "/v1/status" => Some(RouteStatus)
    _ => None
  }
  let route = match route {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.NotFound,
        "not_found",
        request_id,
        @management.RejectedOther,
      )
  }
  if head.method_name != "GET" {
    return self.reject(
      @http_transport.MethodNotAllowed,
      "method_not_allowed",
      request_id,
      @management.RejectedParse,
      allow=@http_transport.AllowGet,
    )
  }
  if now_monotonic_ms < 0L {
    return self.reject(
      @http_transport.ServiceUnavailable,
      "unavailable",
      request_id,
      @management.RejectedStale,
    )
  }
  if @budget.admit([(self.request_bucket, 1L)], now_monotonic_ms) is Err(_) {
    return self.reject(
      @http_transport.TooManyRequests,
      "rate_limited",
      request_id,
      @management.RejectedRate,
    )
  }
  if route == RouteLive || route == RouteReady {
    let decision = match self.cache.health(now_monotonic_ms) {
      Ok(value) => value
      Err(_) =>
        return self.reject(
          @http_transport.ServiceUnavailable,
          "unavailable",
          request_id,
          @management.RejectedStale,
        )
    }
    let healthy = if route == RouteLive {
      decision.live
    } else {
      decision.ready
    }
    return self.encode(
      if healthy {
        @http_transport.Ok
      } else {
        @http_transport.ServiceUnavailable
      },
      if route == RouteLive {
        @management.encode_health_live(decision)
      } else {
        @management.encode_health_ready(decision)
      },
      @http_transport.JsonBody,
    )
  }
  let token = match management_header(head, "authorization") {
    Some(value) => management_bearer(value)
    None => None
  }
  let actor = match token {
    Some(value) => self.tokens.authenticate(value)
    None => None
  }
  let actor = match actor {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.Unauthorized,
        "unauthenticated",
        request_id,
        @management.RejectedAuth,
      )
  }
  let needed = if route == RouteMetrics {
    @management.Metrics
  } else {
    @management.Read
  }
  if !actor.allows(needed) {
    return self.reject(
      @http_transport.Forbidden,
      "forbidden",
      request_id,
      @management.RejectedRole,
    )
  }
  let body = if route == RouteMetrics {
    self.cache.render_metrics(now_monotonic_ms, self.rejections)
  } else {
    self.cache.status_body(now_monotonic_ms)
  }
  match body {
    Ok(value) =>
      self.encode(
        @http_transport.Ok,
        value,
        if route == RouteMetrics {
          @http_transport.PrometheusBody
        } else {
          @http_transport.JsonBody
        },
      )
    Err(_) =>
      self.reject(
        @http_transport.ServiceUnavailable,
        "stale",
        request_id,
        @management.RejectedStale,
      )
  }
}
