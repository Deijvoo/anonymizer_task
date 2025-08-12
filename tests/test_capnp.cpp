#include <capnp/message.h>
#include <capnp/serialize.h>
#include <capnp/serialize-packed.h>
#include <kj/array.h>
#include "http_log.capnp.h"

#include <cassert>
#include <cstdint>
#include <string>

int main() {
    // Build a sample HttpLogRecord
    capnp::MallocMessageBuilder message;
    auto root = message.initRoot<HttpLogRecord>();
    root.setTimestampEpochMilli(1710000123456ULL);
    root.setResourceId(42);
    root.setBytesSent(123456);
    root.setRequestTimeMilli(789ULL);
    root.setResponseStatus(200);
    root.setCacheStatus("HIT");
    root.setMethod("GET");
    root.setRemoteAddr("192.168.1.10");
    root.setUrl("/index.html");

    // Serialize to a flat array of words
    kj::Array<capnp::word> flat = capnp::messageToFlatArray(message);

    // Simulate anonymizer's aligned copy + parsing
    capnp::FlatArrayMessageReader reader(flat);
    auto r = reader.getRoot<HttpLogRecord>();

    // Assertions
    assert(r.getTimestampEpochMilli() == 1710000123456ULL);
    assert(r.getResourceId() == 42);
    assert(r.getBytesSent() == 123456);
    assert(r.getRequestTimeMilli() == 789ULL);
    assert(r.getResponseStatus() == 200);
    assert(r.getCacheStatus() == kj::StringPtr("HIT"));
    assert(r.getMethod() == kj::StringPtr("GET"));
    assert(r.getRemoteAddr() == kj::StringPtr("192.168.1.10"));
    assert(r.getUrl() == kj::StringPtr("/index.html"));

    return 0;
}

