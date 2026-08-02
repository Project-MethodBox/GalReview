#include "json.hpp"

#include <charconv>
#include <cmath>

namespace rt::json
{
namespace
{

struct Parser
{
    std::string_view text;
    std::size_t pos = 0;
    std::size_t maxDepth = 96;
    std::string error;
    std::size_t errorOffset = 0;

    bool fail(std::string message)
    {
        if (error.empty())
        {
            error = std::move(message);
            errorOffset = pos;
        }
        return false;
    }

    bool atEnd() const { return pos >= text.size(); }
    char peek() const { return text[pos]; }

    void skipWhitespace()
    {
        while (!atEnd())
        {
            const char c = text[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
            {
                ++pos;
                continue;
            }
            break;
        }
    }

    bool consumeLiteral(std::string_view literal)
    {
        if (text.substr(pos, literal.size()) != literal)
        {
            return fail("invalid literal");
        }
        pos += literal.size();
        return true;
    }

    static void appendUtf8(std::string& out, std::uint32_t codepoint)
    {
        if (codepoint <= 0x7F)
        {
            out.push_back(static_cast<char>(codepoint));
        }
        else if (codepoint <= 0x7FF)
        {
            out.push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
        }
        else if (codepoint <= 0xFFFF)
        {
            out.push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
        }
        else
        {
            out.push_back(static_cast<char>(0xF0 | (codepoint >> 18)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
        }
    }

    bool parseHex4(std::uint32_t& out)
    {
        if (pos + 4 > text.size())
        {
            return fail("truncated \\u escape");
        }
        std::uint32_t value = 0;
        for (int i = 0; i < 4; ++i)
        {
            const char c = text[pos + static_cast<std::size_t>(i)];
            value <<= 4;
            if (c >= '0' && c <= '9')
            {
                value |= static_cast<std::uint32_t>(c - '0');
            }
            else if (c >= 'a' && c <= 'f')
            {
                value |= static_cast<std::uint32_t>(c - 'a' + 10);
            }
            else if (c >= 'A' && c <= 'F')
            {
                value |= static_cast<std::uint32_t>(c - 'A' + 10);
            }
            else
            {
                return fail("invalid \\u escape digit");
            }
        }
        pos += 4;
        out = value;
        return true;
    }

    bool parseString(std::string& out)
    {
        // caller consumed the opening quote
        out.clear();
        while (true)
        {
            if (atEnd())
            {
                return fail("unterminated string");
            }
            const unsigned char c = static_cast<unsigned char>(text[pos]);
            if (c == '"')
            {
                ++pos;
                return true;
            }
            if (c == '\\')
            {
                ++pos;
                if (atEnd())
                {
                    return fail("unterminated escape");
                }
                const char e = text[pos];
                ++pos;
                switch (e)
                {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u':
                {
                    std::uint32_t unit = 0;
                    if (!parseHex4(unit))
                    {
                        return false;
                    }
                    if (unit >= 0xD800 && unit <= 0xDBFF)
                    {
                        if (pos + 2 > text.size() || text[pos] != '\\' || text[pos + 1] != 'u')
                        {
                            return fail("high surrogate without low surrogate");
                        }
                        pos += 2;
                        std::uint32_t low = 0;
                        if (!parseHex4(low))
                        {
                            return false;
                        }
                        if (low < 0xDC00 || low > 0xDFFF)
                        {
                            return fail("invalid low surrogate");
                        }
                        const std::uint32_t codepoint =
                            0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                        appendUtf8(out, codepoint);
                    }
                    else if (unit >= 0xDC00 && unit <= 0xDFFF)
                    {
                        return fail("stray low surrogate");
                    }
                    else
                    {
                        appendUtf8(out, unit);
                    }
                    break;
                }
                default:
                    return fail("invalid escape character");
                }
                continue;
            }
            if (c < 0x20)
            {
                return fail("unescaped control character in string");
            }
            out.push_back(static_cast<char>(c));
            ++pos;
        }
    }

    bool parseNumber(Value& out)
    {
        const std::size_t start = pos;
        bool negative = false;
        if (!atEnd() && peek() == '-')
        {
            negative = true;
            ++pos;
        }
        if (atEnd() || peek() < '0' || peek() > '9')
        {
            return fail("invalid number");
        }
        if (peek() == '0')
        {
            ++pos;
        }
        else
        {
            while (!atEnd() && peek() >= '0' && peek() <= '9')
            {
                ++pos;
            }
        }
        if (!atEnd() && peek() == '.')
        {
            ++pos;
            if (atEnd() || peek() < '0' || peek() > '9')
            {
                return fail("invalid number fraction");
            }
            while (!atEnd() && peek() >= '0' && peek() <= '9')
            {
                ++pos;
            }
        }
        bool positiveExponent = true;
        bool hasExponent = false;
        if (!atEnd() && (peek() == 'e' || peek() == 'E'))
        {
            hasExponent = true;
            ++pos;
            if (!atEnd() && (peek() == '+' || peek() == '-'))
            {
                positiveExponent = peek() == '+';
                ++pos;
            }
            if (atEnd() || peek() < '0' || peek() > '9')
            {
                return fail("invalid number exponent");
            }
            while (!atEnd() && peek() >= '0' && peek() <= '9')
            {
                ++pos;
            }
        }

        const std::string_view token = text.substr(start, pos - start);
        double parsed = 0.0;
        const auto result = std::from_chars(token.data(), token.data() + token.size(), parsed);
        if (result.ec == std::errc::result_out_of_range)
        {
            // Mirror JSON.parse: overflow becomes +/-Infinity, underflow
            // becomes zero. Downstream validators treat Infinity as a
            // non-finite number, exactly like the JS adapter does.
            if (hasExponent && !positiveExponent)
            {
                parsed = negative ? -0.0 : 0.0;
            }
            else
            {
                parsed = negative ? -HUGE_VAL : HUGE_VAL;
            }
        }
        else if (result.ec != std::errc())
        {
            return fail("unparseable number");
        }
        out = Value::number(parsed);
        return true;
    }

    bool parseValue(Value& out, std::size_t depth)
    {
        if (depth > maxDepth)
        {
            return fail("maximum nesting depth exceeded");
        }
        skipWhitespace();
        if (atEnd())
        {
            return fail("unexpected end of input");
        }
        const char c = peek();
        switch (c)
        {
        case 'n':
            if (!consumeLiteral("null"))
            {
                return false;
            }
            out = Value::null();
            return true;
        case 't':
            if (!consumeLiteral("true"))
            {
                return false;
            }
            out = Value::boolean(true);
            return true;
        case 'f':
            if (!consumeLiteral("false"))
            {
                return false;
            }
            out = Value::boolean(false);
            return true;
        case '"':
        {
            ++pos;
            std::string text_;
            if (!parseString(text_))
            {
                return false;
            }
            out = Value::string(std::move(text_));
            return true;
        }
        case '[':
        {
            ++pos;
            out = Value::array();
            skipWhitespace();
            if (!atEnd() && peek() == ']')
            {
                ++pos;
                return true;
            }
            while (true)
            {
                Value item;
                if (!parseValue(item, depth + 1))
                {
                    return false;
                }
                out.push(std::move(item));
                skipWhitespace();
                if (atEnd())
                {
                    return fail("unterminated array");
                }
                if (peek() == ',')
                {
                    ++pos;
                    continue;
                }
                if (peek() == ']')
                {
                    ++pos;
                    return true;
                }
                return fail("expected ',' or ']' in array");
            }
        }
        case '{':
        {
            ++pos;
            out = Value::object();
            skipWhitespace();
            if (!atEnd() && peek() == '}')
            {
                ++pos;
                return true;
            }
            while (true)
            {
                skipWhitespace();
                if (atEnd() || peek() != '"')
                {
                    return fail("expected object key");
                }
                ++pos;
                std::string key;
                if (!parseString(key))
                {
                    return false;
                }
                skipWhitespace();
                if (atEnd() || peek() != ':')
                {
                    return fail("expected ':' after object key");
                }
                ++pos;
                Value member;
                if (!parseValue(member, depth + 1))
                {
                    return false;
                }
                out.members().emplace_back(std::move(key), std::move(member));
                skipWhitespace();
                if (atEnd())
                {
                    return fail("unterminated object");
                }
                if (peek() == ',')
                {
                    ++pos;
                    continue;
                }
                if (peek() == '}')
                {
                    ++pos;
                    return true;
                }
                return fail("expected ',' or '}' in object");
            }
        }
        default:
            if ((c >= '0' && c <= '9') || c == '-')
            {
                return parseNumber(out);
            }
            return fail("unexpected character");
        }
    }
};

void serializeString(const std::string& value, std::string& out)
{
    static constexpr char hexDigits[] = "0123456789abcdef";
    out.push_back('"');
    for (const char raw : value)
    {
        const unsigned char c = static_cast<unsigned char>(raw);
        switch (c)
        {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20)
            {
                out += "\\u00";
                out.push_back(hexDigits[c >> 4]);
                out.push_back(hexDigits[c & 0x0F]);
            }
            else
            {
                out.push_back(raw);
            }
        }
    }
    out.push_back('"');
}

void serializeNumber(double value, std::string& out)
{
    if (!std::isfinite(value))
    {
        // JSON cannot express NaN/Infinity; JSON.stringify emits null too.
        out += "null";
        return;
    }
    if (value == 0.0)
    {
        // JSON.stringify(-0) === "0"; keep negative zero out of the wire.
        out += "0";
        return;
    }
    char buffer[32];
    const auto result = std::to_chars(buffer, buffer + sizeof(buffer), value);
    out.append(buffer, result.ptr);
}

void serializeValue(const Value& value, std::string& out)
{
    switch (value.type())
    {
    case Type::Null:
        out += "null";
        return;
    case Type::Boolean:
        out += value.asBoolean() ? "true" : "false";
        return;
    case Type::Number:
        serializeNumber(value.asNumber(), out);
        return;
    case Type::String:
        serializeString(value.asString(), out);
        return;
    case Type::Array:
    {
        out.push_back('[');
        bool first = true;
        for (const Value& item : value.items())
        {
            if (!first)
            {
                out.push_back(',');
            }
            first = false;
            serializeValue(item, out);
        }
        out.push_back(']');
        return;
    }
    case Type::Object:
    {
        out.push_back('{');
        bool first = true;
        for (const Value::Member& member : value.members())
        {
            if (!first)
            {
                out.push_back(',');
            }
            first = false;
            serializeString(member.first, out);
            out.push_back(':');
            serializeValue(member.second, out);
        }
        out.push_back('}');
        return;
    }
    }
}

} // namespace

Value Value::boolean(bool v)
{
    Value value;
    value.type_ = Type::Boolean;
    value.bool_ = v;
    return value;
}

Value Value::number(double v)
{
    Value value;
    value.type_ = Type::Number;
    value.number_ = v;
    return value;
}

Value Value::string(std::string v)
{
    Value value;
    value.type_ = Type::String;
    value.string_ = std::move(v);
    return value;
}

Value Value::array()
{
    Value value;
    value.type_ = Type::Array;
    return value;
}

Value Value::object()
{
    Value value;
    value.type_ = Type::Object;
    return value;
}

const Value* Value::find(std::string_view key) const
{
    if (type_ != Type::Object)
    {
        return nullptr;
    }
    for (auto it = members_.rbegin(); it != members_.rend(); ++it)
    {
        if (it->first == key)
        {
            return &it->second;
        }
    }
    return nullptr;
}

void Value::set(std::string key, Value v)
{
    for (auto it = members_.rbegin(); it != members_.rend(); ++it)
    {
        if (it->first == key)
        {
            it->second = std::move(v);
            return;
        }
    }
    members_.emplace_back(std::move(key), std::move(v));
}

void Value::push(Value v)
{
    items_.push_back(std::move(v));
}

ParseResult parse(std::string_view text, std::size_t maxDepth)
{
    Parser parser;
    parser.text = text;
    parser.maxDepth = maxDepth;

    ParseResult result;
    if (!parser.parseValue(result.value, 0))
    {
        result.error = parser.error.empty() ? "invalid JSON" : parser.error;
        result.offset = parser.errorOffset;
        return result;
    }
    parser.skipWhitespace();
    if (!parser.atEnd())
    {
        result.error = "trailing characters after JSON value";
        result.offset = parser.pos;
        result.value = Value();
        return result;
    }
    result.ok = true;
    return result;
}

std::string serialize(const Value& value)
{
    std::string out;
    serializeValue(value, out);
    return out;
}

} // namespace rt::json
