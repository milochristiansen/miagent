// Configuration: the user-level directory holding the prompts, the base tools,
// and the core dotenv file, plus the two dotenv files a run is configured from.
// The directory is resolved between the two files, so a project's local .env
// can point the harness at a different installation.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
)

// configName is the directory under the XDG config home that holds this
// program's files when MIAGENT_CONFIG_DIR does not name one.
const configName = "miagent"

// configDirEnv is the environment variable naming the configuration directory.
// When it is set the harness loads from there; when it is not, the directory is
// resolved from the XDG variables and canonicalConfigDir records the result in
// this variable, so the whole process — and every tool it runs — agrees on one
// path.
const configDirEnv = "MIAGENT_CONFIG_DIR"

// configDir returns the configuration directory: MIAGENT_CONFIG_DIR when it is
// set and non-empty, otherwise $XDG_CONFIG_HOME/miagent, or ~/.config/miagent
// when XDG_CONFIG_HOME is unset.
//
// An explicit MIAGENT_CONFIG_DIR is used as given (cleaned, but not required to
// be absolute), because it is the caller's deliberate choice. The XDG basedir
// convention is still followed for XDG_CONFIG_HOME itself: an empty or relative
// value is ignored in favour of the default, because a relative config home
// would depend on the working directory.
func configDir() (string, error) {
	if dir := os.Getenv(configDirEnv); dir != "" {
		return filepath.Clean(dir), nil
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" || !filepath.IsAbs(base) {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("cannot find the configuration directory (set %s or XDG_CONFIG_HOME): %w", configDirEnv, err)
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, configName), nil
}

// canonicalConfigDir resolves the configuration directory and, when
// MIAGENT_CONFIG_DIR was not set, records the result in it. Every process the
// harness starts inherits the environment, so a tool can read
// MIAGENT_CONFIG_DIR to find the prompts, core .env, and base tools the
// harness loaded, without repeating the XDG resolution.
func canonicalConfigDir() (string, error) {
	dir, err := configDir()
	if err != nil {
		return "", err
	}
	if os.Getenv(configDirEnv) == "" {
		if err := os.Setenv(configDirEnv, dir); err != nil {
			return "", fmt.Errorf("setting %s: %w", configDirEnv, err)
		}
	}
	return dir, nil
}

// loadConfig configures a run from the two dotenv files and the directory
// between them.
//
// The local .env is read first, because it sits at a fixed path and is the one
// place a project can point MIAGENT_CONFIG_DIR at a different installation; the
// configuration directory is then resolved and recorded; and the core .env is
// read last, from the directory that was just resolved.
//
// Precedence, highest first: the process environment, the local .env, the core
// .env. Reading the local file first and leaving every variable already set
// alone gives both rules: an exported variable beats every file, and a
// project's file beats the installation's. The core .env cannot move
// MIAGENT_CONFIG_DIR once it is recorded, because it is read from the directory
// that value chose.
//
// A missing file is not an error; a malformed one is, and names the file. An
// environment that silently lost half its settings to a typo is worse than a
// startup that says which line is wrong.
func loadConfig(stateDir string) error {
	if err := loadDotenv(filepath.Join(stateDir, ".env")); err != nil {
		return err
	}
	config, err := canonicalConfigDir()
	if err != nil {
		return err
	}
	return loadDotenv(filepath.Join(config, ".env"))
}

// loadDotenv sets the variables in one dotenv file that are not already set in
// the process environment. A variable already set — exported in the shell or
// applied from a file read earlier — is left alone, which is what gives the
// precedence loadConfig documents. A missing file is not an error; a malformed
// one is, and names the file.
func loadDotenv(path string) error {
	err := godotenv.Load(path)
	if err == nil || os.IsNotExist(err) {
		return nil
	}
	return fmt.Errorf("%s: %w", path, err)
}
