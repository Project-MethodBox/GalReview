// RenderService runtime core - minimal exception-free JSON tree.
//
// Scope: exactly what the frozen contract surfaces need (game packages,
// review sessions, runtime inputs/events/state). Strict RFC 8259 parsing,
// compact serialization, UTF-8 passthrough. No exceptions are thrown by
// this module; parse failures are reported through ParseResult.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace rt::json
{

enum class Type : std::uint8_t
{
    Null,
    Boolean,
    Number,
    String,
    Array,
    Object,
};

class Value
{
public:
    using Member = std::pair<std::string, Value>;

    Value() = default;

    static Value null() { return Value(); }
    static Value boolean(bool v);
    static Value number(double v);
    static Value string(std::string v);
    static Value array();
    static Value object();

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }
    bool isBoolean() const { return type_ == Type::Boolean; }
    bool isNumber() const { return type_ == Type::Number; }
    bool isString() const { return type_ == Type::String; }
    bool isArray() const { return type_ == Type::Array; }
    bool isObject() const { return type_ == Type::Object; }

    bool asBoolean() const { return bool_; }
    double asNumber() const { return number_; }
    const std::string& asString() const { return string_; }

    const std::vector<Value>& items() const { return items_; }
    std::vector<Value>& items() { return items_; }
    const std::vector<Member>& members() const { return members_; }
    std::vector<Member>& members() { return members_; }

    // Object lookup. Scans backwards so duplicate keys resolve to the last
    // occurrence, matching what JSON.parse produces for the JS adapter.
    const Value* find(std::string_view key) const;

    // Object append-or-replace and array append helpers for building output.
    void set(std::string key, Value v);
    void push(Value v);

private:
    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0.0;
    std::string string_;
    std::vector<Value> items_;
    std::vector<Member> members_;
};

struct ParseResult
{
    bool ok = false;
    Value value;
    std::string error;      // empty when ok
    std::size_t offset = 0; // byte offset the error was detected at
};

ParseResult parse(std::string_view text, std::size_t maxDepth = 96);

// Compact serialization: members keep insertion order, numbers use the
// shortest round-trip form, non-ASCII UTF-8 passes through unescaped.
std::string serialize(const Value& value);

} // namespace rt::json
