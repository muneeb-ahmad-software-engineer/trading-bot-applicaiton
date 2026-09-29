//+------------------------------------------------------------------+
//| Api.mqh                                                           |
//| HTTP client for the GoldGrid platform.                            |
//|                                                                   |
//| Two rules govern everything here:                                 |
//|                                                                   |
//|  1. Failure is never silent. Every non-success outcome sets a     |
//|     reason the EA can act on and show the user.                   |
//|  2. Failure fails closed. If the platform cannot be reached or    |
//|     answers with 401, the caller must not open new positions.     |
//|     Managing what is already open continues.                      |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_API_MQH
#define GOLDGRID_API_MQH

#include "Json.mqh"

enum ENUM_API_RESULT
  {
   API_OK,
   API_NOT_ALLOWED,     // URL not whitelisted in terminal settings
   API_NETWORK_ERROR,   // could not reach the platform
   API_UNAUTHORIZED,    // token invalid or revoked
   API_RATE_LIMITED,
   API_SERVER_ERROR,
   API_BAD_RESPONSE     // reached it, could not understand the answer
  };

class CGoldGridApi
  {
private:
   string            m_base_url;
   string            m_token;
   int               m_timeout_ms;
   string            m_last_error;
   int               m_last_status;

   string            BuildHeaders(void) const
     {
      return "Content-Type: application/json\r\n"
             "Accept: application/json\r\n"
             "Authorization: Bearer " + m_token + "\r\n";
     }

   ENUM_API_RESULT   Request(const string method, const string path, const string body, string &response)
     {
      m_last_error  = "";
      m_last_status = 0;
      response      = "";

      string url = m_base_url + path;

      char   post[];
      char   result[];
      string result_headers;

      if(StringLen(body) > 0)
        {
         //--- StringToCharArray appends a terminating zero; WebRequest must not
         //--- send it, so the array is trimmed by one.
         int size = StringToCharArray(body, post, 0, WHOLE_ARRAY, CP_UTF8) - 1;
         if(size < 0)
            size = 0;
         ArrayResize(post, size);
        }
      else
        {
         ArrayResize(post, 0);
        }

      ResetLastError();
      int status = WebRequest(method, url, BuildHeaders(), m_timeout_ms, post, result, result_headers);
      m_last_status = status;

      if(status == -1)
        {
         int error = GetLastError();
         if(error == 4014 || error == 4060)
           {
            //--- The single most common setup failure, and the one that looks
            //--- least like itself: MetaTrader refuses the call before any
            //--- network traffic happens, so nothing appears in a server log
            //--- and the platform looks unreachable. Quote the address so a
            //--- mismatch is visible, and say where it has to be typed —
            //--- including that MetaTrader only saves it on a clean exit,
            //--- which is what makes a correctly entered URL vanish.
            m_last_error = "URL not allowed (MQL error " + IntegerToString(error) + "). " +
                           "In Tools > Options > Experts, tick \"Allow WebRequest for listed URL\" " +
                           "and add this address exactly: \"" + m_base_url + "\" " +
                           "(it must match character for character, including http:// and the port). " +
                           "Then quit MetaTrader normally so the setting is saved.";

            //--- MetaTrader's whitelist rejects a host with no dot in it, so
            //--- "localhost" can never be added however carefully it is typed.
            //--- Telling someone to enter an address the dialog will refuse
            //--- sends them round the same loop indefinitely, so name the
            //--- substitution instead of repeating the instruction.
            if(StringFind(m_base_url, "localhost") >= 0)
               m_last_error += " NOTE: MetaTrader will not accept \"localhost\" in that list — "
                               "a host name there must contain a dot. Use 127.0.0.1 instead: "
                               "whitelist \"http://127.0.0.1:3000\" AND set this EA's Platform URL "
                               "input to the same thing. They are the same machine.";
            return API_NOT_ALLOWED;
           }
         //--- 5200-5203 are WebRequest's own failures: bad address, connection
         //--- refused, timeout. Those mean the whitelist is fine and something
         //--- else is wrong, which is worth distinguishing loudly.
         m_last_error = "Network error " + IntegerToString(error) + " calling " + url +
                        (error >= 5200 && error <= 5203
                         ? " (the URL is allowed, but the request itself failed — is the platform running?)"
                         : "");
         return API_NETWORK_ERROR;
        }

      response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

      if(status == 401)
        {
         m_last_error = "API token rejected. It may have been revoked, or the account password was reset.";
         return API_UNAUTHORIZED;
        }
      if(status == 429)
        {
         m_last_error = "Rate limited by the platform.";
         return API_RATE_LIMITED;
        }
      if(status >= 500)
        {
         m_last_error = "Platform error (HTTP " + IntegerToString(status) + ").";
         return API_SERVER_ERROR;
        }
      if(status < 200 || status >= 300)
        {
         m_last_error = "Unexpected response (HTTP " + IntegerToString(status) + "): " + StringSubstr(response, 0, 200);
         return API_BAD_RESPONSE;
        }

      return API_OK;
     }

public:
                     CGoldGridApi(void) { m_timeout_ms = 8000; m_last_status = 0; }

   void              Configure(const string base_url, const string token, const int timeout_ms = 8000)
     {
      m_base_url = base_url;
      //--- A trailing slash would produce a double slash in every path.
      while(StringLen(m_base_url) > 0 && StringGetCharacter(m_base_url, StringLen(m_base_url) - 1) == '/')
         m_base_url = StringSubstr(m_base_url, 0, StringLen(m_base_url) - 1);

      m_token      = token;
      m_timeout_ms = timeout_ms;
     }

   string            LastError(void)  const { return m_last_error; }
   int               LastStatus(void) const { return m_last_status; }

   //--- Fetches one strategy. Caller owns and must delete the returned node.
   ENUM_API_RESULT   FetchStrategy(const long strategy_id, CJsonNode *&strategy)
     {
      strategy = NULL;

      string response;
      ENUM_API_RESULT result = Request("GET", "/api/v1/strategies/" + IntegerToString(strategy_id), "", response);
      if(result != API_OK)
         return result;

      CJsonParser parser;
      CJsonNode *root = parser.Parse(response);
      if(CheckPointer(root) == POINTER_INVALID)
        {
         m_last_error = "Could not parse the strategy response.";
         return API_BAD_RESPONSE;
        }

      CJsonNode *node = root.Get("strategy");
      if(CheckPointer(node) == POINTER_INVALID)
        {
         delete root;
         m_last_error = "Strategy response did not contain a strategy.";
         return API_BAD_RESPONSE;
        }

      //--- Hand back the whole document; the caller reads through it and frees
      //--- it. Detaching the child would leak the rest of the tree.
      strategy = root;
      return API_OK;
     }

   //--- `response` carries the platform's reply, which includes the current
   //--- config_version of the strategy.
   ENUM_API_RESULT   PostReport(const string json_body, string &response)
     {
      return Request("POST", "/api/v1/trading/report", json_body, response);
     }

   ENUM_API_RESULT   Ping(void)
     {
      string response;
      return Request("GET", "/api/v1/status", "", response);
     }
  };

#endif
