//+------------------------------------------------------------------+
//| Json.mqh                                                          |
//| Minimal recursive-descent JSON parser.                            |
//|                                                                   |
//| MQL5 has no JSON support. Extracting values by searching the raw  |
//| response string is a common shortcut and a bad one: it breaks on  |
//| nested objects and on any string containing a brace. This parses  |
//| properly, because the values it reads decide whether real orders  |
//| are placed.                                                       |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_JSON_MQH
#define GOLDGRID_JSON_MQH

enum ENUM_JSON_TYPE
  {
   JSON_UNDEFINED,
   JSON_NULL,
   JSON_BOOL,
   JSON_NUMBER,
   JSON_STRING,
   JSON_ARRAY,
   JSON_OBJECT
  };

//+------------------------------------------------------------------+
//| One node of the parsed document. Owns its children.               |
//+------------------------------------------------------------------+
class CJsonNode
  {
private:
   CJsonNode        *m_children[];
   string            m_keys[];

public:
   ENUM_JSON_TYPE    type;
   string            str_value;
   double            num_value;
   bool              bool_value;

                     CJsonNode(void) { type = JSON_UNDEFINED; num_value = 0.0; bool_value = false; }
                    ~CJsonNode(void) { Clear(); }

   void              Clear(void)
     {
      for(int i = 0; i < ArraySize(m_children); i++)
         if(CheckPointer(m_children[i]) == POINTER_DYNAMIC)
            delete m_children[i];
      ArrayResize(m_children, 0);
      ArrayResize(m_keys, 0);
     }

   void              Add(const string key, CJsonNode *node)
     {
      int n = ArraySize(m_children);
      ArrayResize(m_children, n + 1);
      ArrayResize(m_keys, n + 1);
      m_children[n] = node;
      m_keys[n] = key;
     }

   int               Size(void) const { return ArraySize(m_children); }

   CJsonNode        *At(const int index) const
     {
      if(index < 0 || index >= ArraySize(m_children))
         return NULL;
      return m_children[index];
     }

   CJsonNode        *Get(const string key) const
     {
      for(int i = 0; i < ArraySize(m_keys); i++)
         if(m_keys[i] == key)
            return m_children[i];
      return NULL;
     }

   bool              IsNull(void) const { return type == JSON_NULL; }

   //--- Accessors take a default, so a missing or null field never silently
   //--- becomes zero and is then used as a trading parameter.
   string            AsString(const string fallback = "") const
     {
      if(type == JSON_STRING) return str_value;
      if(type == JSON_NUMBER) return DoubleToString(num_value, 8);
      if(type == JSON_BOOL)   return bool_value ? "true" : "false";
      return fallback;
     }

   double            AsDouble(const double fallback = 0.0) const
     {
      if(type == JSON_NUMBER) return num_value;
      //--- The API sends money and lot values as strings on purpose, to keep
      //--- decimal precision. Accept both.
      if(type == JSON_STRING) return StringToDouble(str_value);
      return fallback;
     }

   int               AsInt(const int fallback = 0) const
     {
      if(type == JSON_NUMBER) return (int)MathRound(num_value);
      if(type == JSON_STRING) return (int)StringToInteger(str_value);
      return fallback;
     }

   bool              AsBool(const bool fallback = false) const
     {
      if(type == JSON_BOOL)   return bool_value;
      if(type == JSON_STRING) return str_value == "true";
      if(type == JSON_NUMBER) return num_value != 0.0;
      return fallback;
     }
  };

//+------------------------------------------------------------------+
//| Parser.                                                           |
//+------------------------------------------------------------------+
class CJsonParser
  {
private:
   string            m_text;
   int               m_pos;
   int               m_len;

   void              SkipWhitespace(void)
     {
      while(m_pos < m_len)
        {
         ushort c = StringGetCharacter(m_text, m_pos);
         if(c == ' ' || c == '\t' || c == '\n' || c == '\r')
            m_pos++;
         else
            break;
        }
     }

   bool              Expect(const ushort ch)
     {
      SkipWhitespace();
      if(m_pos < m_len && StringGetCharacter(m_text, m_pos) == ch)
        {
         m_pos++;
         return true;
        }
      return false;
     }

   bool              ParseString(string &out)
     {
      SkipWhitespace();
      if(m_pos >= m_len || StringGetCharacter(m_text, m_pos) != '"')
         return false;
      m_pos++;

      out = "";
      while(m_pos < m_len)
        {
         ushort c = StringGetCharacter(m_text, m_pos);
         m_pos++;

         if(c == '"')
            return true;

         if(c != '\\')
           {
            out += ShortToString(c);
            continue;
           }

         if(m_pos >= m_len)
            return false;

         ushort esc = StringGetCharacter(m_text, m_pos);
         m_pos++;

         switch(esc)
           {
            case '"':  out += "\"";      break;
            case '\\': out += "\\";      break;
            case '/':  out += "/";       break;
            case 'b':  out += ShortToString(8);  break;
            case 'f':  out += ShortToString(12); break;
            case 'n':  out += "\n";      break;
            case 'r':  out += "\r";      break;
            case 't':  out += "\t";      break;
            case 'u':
              {
               if(m_pos + 4 > m_len)
                  return false;
               string hex = StringSubstr(m_text, m_pos, 4);
               m_pos += 4;
               out += ShortToString((ushort)StringToInteger("0x" + hex));
               break;
              }
            default:
               return false;
           }
        }
      return false;
     }

   bool              ParseNumber(double &out)
     {
      SkipWhitespace();
      int start = m_pos;
      while(m_pos < m_len)
        {
         ushort c = StringGetCharacter(m_text, m_pos);
         if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')
            m_pos++;
         else
            break;
        }
      if(m_pos == start)
         return false;
      out = StringToDouble(StringSubstr(m_text, start, m_pos - start));
      return true;
     }

   bool              MatchLiteral(const string literal)
     {
      SkipWhitespace();
      if(m_pos + StringLen(literal) > m_len)
         return false;
      if(StringSubstr(m_text, m_pos, StringLen(literal)) != literal)
         return false;
      m_pos += StringLen(literal);
      return true;
     }

   bool              ParseValue(CJsonNode *&out)
     {
      SkipWhitespace();
      if(m_pos >= m_len)
         return false;

      ushort c = StringGetCharacter(m_text, m_pos);

      if(c == '{')
         return ParseObject(out);
      if(c == '[')
         return ParseArray(out);

      if(c == '"')
        {
         string s;
         if(!ParseString(s))
            return false;
         out = new CJsonNode();
         out.type = JSON_STRING;
         out.str_value = s;
         return true;
        }

      if(MatchLiteral("true"))
        {
         out = new CJsonNode();
         out.type = JSON_BOOL;
         out.bool_value = true;
         return true;
        }

      if(MatchLiteral("false"))
        {
         out = new CJsonNode();
         out.type = JSON_BOOL;
         out.bool_value = false;
         return true;
        }

      if(MatchLiteral("null"))
        {
         out = new CJsonNode();
         out.type = JSON_NULL;
         return true;
        }

      double number;
      if(ParseNumber(number))
        {
         out = new CJsonNode();
         out.type = JSON_NUMBER;
         out.num_value = number;
         return true;
        }

      return false;
     }

   bool              ParseArray(CJsonNode *&out)
     {
      if(!Expect('['))
         return false;

      out = new CJsonNode();
      out.type = JSON_ARRAY;

      SkipWhitespace();
      if(Expect(']'))
         return true;

      while(true)
        {
         CJsonNode *item = NULL;
         if(!ParseValue(item))
           {
            delete out;
            out = NULL;
            return false;
           }
         out.Add("", item);

         if(Expect(','))
            continue;
         if(Expect(']'))
            return true;

         delete out;
         out = NULL;
         return false;
        }

      // Unreachable: every path inside the loop above returns. MQL5's compiler
      // cannot prove that of `while(true)`, so it requires a return here.
      return false;
     }

   bool              ParseObject(CJsonNode *&out)
     {
      if(!Expect('{'))
         return false;

      out = new CJsonNode();
      out.type = JSON_OBJECT;

      SkipWhitespace();
      if(Expect('}'))
         return true;

      while(true)
        {
         string key;
         if(!ParseString(key) || !Expect(':'))
           {
            delete out;
            out = NULL;
            return false;
           }

         CJsonNode *value = NULL;
         if(!ParseValue(value))
           {
            delete out;
            out = NULL;
            return false;
           }
         out.Add(key, value);

         if(Expect(','))
            continue;
         if(Expect('}'))
            return true;

         delete out;
         out = NULL;
         return false;
        }

      // Unreachable: every path inside the loop above returns. MQL5's compiler
      // cannot prove that of `while(true)`, so it requires a return here.
      return false;
     }

public:
   //--- Returns NULL on malformed input. The caller owns the result and must
   //--- delete it.
   CJsonNode        *Parse(const string text)
     {
      m_text = text;
      m_pos  = 0;
      m_len  = StringLen(text);

      CJsonNode *root = NULL;
      if(!ParseValue(root))
        {
         if(CheckPointer(root) == POINTER_DYNAMIC)
            delete root;
         return NULL;
        }
      return root;
     }
  };

//+------------------------------------------------------------------+
//| Look up a nested value, e.g. JsonPath(root, "grid/levels").        |
//+------------------------------------------------------------------+
CJsonNode *JsonPath(CJsonNode *root, const string path)
  {
   if(CheckPointer(root) == POINTER_INVALID)
      return NULL;

   string parts[];
   int count = StringSplit(path, '/', parts);

   CJsonNode *node = root;
   for(int i = 0; i < count; i++)
     {
      if(CheckPointer(node) == POINTER_INVALID)
         return NULL;
      node = node.Get(parts[i]);
     }
   return node;
  }

//+------------------------------------------------------------------+
//| Escape a string for embedding in JSON output.                     |
//+------------------------------------------------------------------+
string JsonEscape(const string value)
  {
   string out = "";
   int len = StringLen(value);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(value, i);
      switch(c)
        {
         case '"':  out += "\\\"";  break;
         case '\\': out += "\\\\";  break;
         case '\n': out += "\\n";   break;
         case '\r': out += "\\r";   break;
         case '\t': out += "\\t";   break;
         default:
            if(c < 32)
               out += StringFormat("\\u%04x", c);
            else
               out += ShortToString(c);
        }
     }
   return out;
  }

#endif
