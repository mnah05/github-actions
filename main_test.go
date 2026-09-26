package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHelloHandler_Default(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	helloHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, want %d", rec.Code, http.StatusOK)
	}
	if got, want := rec.Body.String(), "Hello, World!\n"; got != want {
		t.Fatalf("got body %q, want %q", got, want)
	}
}

func TestHelloHandler_WithName(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/?name=Actions", nil)
	rec := httptest.NewRecorder()

	helloHandler(rec, req)

	if got, want := rec.Body.String(), "Hello, Actions!\n"; got != want {
		t.Fatalf("got body %q, want %q", got, want)
	}
}

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	healthHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, want %d", rec.Code, http.StatusOK)
	}
}
