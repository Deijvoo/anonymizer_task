#include "util.h"

#include <cstdio>
#include <cstdlib>

std::string anonymize_ip(std::string_view ip) {
    auto dot = ip.rfind('.');
    return (dot == std::string_view::npos) ? std::string(ip)
                                           : std::string(ip.substr(0, dot)) + ".X";
}

std::string join_rows(const std::vector<std::string> &rows) {
    std::string out;
    out.reserve(rows.size() * 128);
    for (auto const &r : rows) {
        out += r;
        out += '\n';
    }
    return out;
}

std::string getEnvOrDefault(const char* name, const char* fallback) {
    if (const char* v = std::getenv(name); v && *v) return std::string(v);
    return std::string(fallback);
}

std::string escape_json(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[7];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

