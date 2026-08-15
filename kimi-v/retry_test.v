// retry_test.v — unit tests for the agent loop's retry policy helpers.
//
// Pure-function tests only: the retry loop itself drives channels and
// goroutines (provider.chat), which the V test runner can't reap — that
// path is verified manually.
module main

fn test_retry_backoff_base_ms_exponential() {
	// Deterministic base sequence: 500ms * 2^(attempt-1), no jitter.
	assert retry_backoff_base_ms(1) == 500
	assert retry_backoff_base_ms(2) == 1000
	assert retry_backoff_base_ms(3) == 2000
	assert retry_backoff_base_ms(4) == 4000
	assert retry_backoff_base_ms(5) == 8000
	assert retry_backoff_base_ms(6) == 16000
}

fn test_retry_backoff_base_ms_capped_at_32s() {
	assert retry_backoff_base_ms(7) == 32000
	assert retry_backoff_base_ms(8) == 32000
	assert retry_backoff_base_ms(100) == 32000
}

fn test_retry_backoff_ms_jitter_stays_in_range() {
	// Jitter is +0..25% on top of the (capped) base, so every returned
	// value must land in [base, base * 1.25].
	for attempt in 1 .. 20 {
		base := retry_backoff_base_ms(attempt)
		for _ in 0 .. 50 {
			got := retry_backoff_ms(attempt)
			assert got >= base
			assert got <= base * 125 / 100
		}
	}
}

fn test_is_retryable_status() {
	// 429 (rate limit) and 5xx are transient.
	assert is_retryable_status(429)
	assert is_retryable_status(500)
	assert is_retryable_status(502)
	assert is_retryable_status(503)
	// Other 4xx are client errors a retry won't fix.
	assert !is_retryable_status(400)
	assert !is_retryable_status(401)
	assert !is_retryable_status(403)
	assert !is_retryable_status(404)
	assert !is_retryable_status(200)
}

fn test_provider_error_retryable_flag() {
	retryable_err := ProviderError{
		kind:      'http_429'
		message:   'http_429: rate limited'
		retryable: true
	}
	assert retryable_err.retryable
	assert retryable_err.msg() == 'http_429: rate limited'

	fatal_err := ProviderError{
		kind:      'http_400'
		message:   'http_400: bad request'
		retryable: false
	}
	assert !fatal_err.retryable
}
