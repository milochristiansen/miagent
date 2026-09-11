// User-level configuration directory: the prompts (in a prompts subdirectory)
// and the core dotenv file live here rather than in the working directory, so
// one installation serves every project.
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// configName is the directory under the XDG config home that holds this
// program's files.
const configName = "miagent"

// configDir returns the configuration directory: $XDG_CONFIG_HOME/miagent, or
// ~/.config/miagent when XDG_CONFIG_HOME is unset.
//
// The XDG basedir convention is followed for the variable itself: an empty or
// relative value is ignored in favour of the default, because a relative
// config home would depend on the working directory.
func configDir() (string, error) {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" || !filepath.IsAbs(base) {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("cannot find the configuration directory (set XDG_CONFIG_HOME): %w", err)
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, configName), nil
}

// displayConfigDir returns configDir when it can be resolved, and the XDG form
// otherwise, for usage text that must print something either way.
func displayConfigDir() string {
	dir, err := configDir()
	if err != nil {
		return "$XDG_CONFIG_HOME/" + configName
	}
	return dir
}
