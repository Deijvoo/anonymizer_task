#include "util.h"

#include <cassert>
#include <cstdlib>
#include <vector>
#include <string>

int main() {
    // anonymize_ip
    assert(anonymize_ip("1.2.3.4") == std::string("1.2.3.X"));
    assert(anonymize_ip("10.0.0.1") == std::string("10.0.0.X"));
    assert(anonymize_ip("not-an-ip") == std::string("not-an-ip"));

    // escape_json
    std::string escaped = escape_json("a\"b\\c\n\t");
    assert(escaped == std::string("a\\\"b\\\\c\\n\\t"));

    // join_rows
    std::vector<std::string> rows{"row1", "row2"};
    assert(join_rows(rows) == std::string("row1\nrow2\n"));

    // getEnvOrDefault
#ifdef _WIN32
    _putenv_s("UTIL_TEST_FOO", "bar");
#else
    setenv("UTIL_TEST_FOO", "bar", 1);
#endif
    assert(getEnvOrDefault("UTIL_TEST_FOO", "x") == std::string("bar"));
    assert(getEnvOrDefault("UTIL_TEST_MISSING", "fallback") == std::string("fallback"));

    return 0;
}

