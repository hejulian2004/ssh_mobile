// Standalone Admin backend binary entry point.

package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ssh-mobile/relay/internal/admin"
	"github.com/ssh-mobile/relay/internal/diagnostics"
)

func main() {
	if err := diagnostics.InstallFromEnvironment("admin"); err != nil {
		log.Fatal("invalid development diagnostic configuration")
	}
	config, err := admin.ConfigFromEnvironment()
	if err != nil {
		log.Fatalf("admin config error: %v", err)
	}

	server := admin.NewServer(config)
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	httpServer := &http.Server{
		Addr:              config.Address,
		Handler:           mux,
		ReadTimeout:       config.HTTPReadTimeout,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      config.HTTPWriteTimeout,
		IdleTimeout:       config.HTTPIdleTimeout,
		MaxHeaderBytes:    config.HTTPMaxHeaderBytes,
	}

	log.Printf("admin backend listening on %s", config.Address)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-serverErrors:
		if err != nil && err != http.ErrServerClosed {
			log.Printf("admin server stopped: %v", err)
			os.Exit(1)
		}
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("admin HTTP shutdown failed: %v", err)
			_ = httpServer.Close()
		}
		_ = server.Close()
	}
}
