// Environment loading: the harness reads two dotenv files at startup, the core
// one in the configuration directory and the state directory's, so one
// installation can be configured once and a project can still override it.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
)

// loadEnv loads the environment from the core dotenv file in the configuration
// directory and then the state directory's.
//
// Precedence, highest first: variables already set in the process environment,
// then the state directory's .env, then the configuration directory's. A value
// exported in the shell therefore always wins over a file, and the more
// specific file (the one belonging to the project) wins over the general one.
//
// A missing file is not an error; a malformed one is, and names the file. An
// environment that silently lost half its settings to a typo is worse than a
// startup that says which line is wrong.
func loadEnv(stateDir string) error {
	config, err := configDir()
	if err != nil {
		return err
	}

	merged := map[string]string{}
	for _, path := range []string{filepath.Join(config, ".env"), filepath.Join(stateDir, ".env")} {
		values, err := godotenv.Read(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("%s: %w", path, err)
		}
		for key, value := range values {
			merged[key] = value
		}
	}

	for key, value := range merged {
		if _, set := os.LookupEnv(key); set {
			continue
		}
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}
	return nil
}
