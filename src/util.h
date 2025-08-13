#pragma once

#include <string>
#include <string_view>
#include <vector>

// Lightweight helpers (no heavy deps) used across the project

// Masks last IPv4 octet: 1.2.3.4 -> 1.2.3.X ; returns input if not IPv4 dotted
std::string anonymize_ip(std::string_view ip);

// Joins lines with trailing newline per row (ClickHouse JSONEachRow expects newline-separated rows)
std::string join_rows(const std::vector<std::string>& rows);

// Reads env var or returns fallback when unset/empty
std::string getEnvOrDefault(const char* name, const char* fallback);

// Reads env var or throws if unset/empty. Use for required config.
std::string getRequiredEnv(const char* name);

// Escapes a string for safe JSON emission
std::string escape_json(std::string_view s);

