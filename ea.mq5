#property strict
#property version "4.32"

#include <Trade/Trade.mqh>

CTrade trade;

//================ INPUTS =================//

input string API                = "http://host:3001/pull";
input int    POLL_SECONDS       = 1;
input long   MAGIC              = 123456789;
input string COMMENT_TXT        = "";
input bool   DEBUG_LOG          = true;

// Thời hạn của pending LIMIT, tính từ lúc EA nhận tín hiệu.
// Đặt 0 để dùng GTC.
input int    LIMIT_EXPIRY_HOURS = 4;

//================ BROKER SYMBOL CONFIG =================//
//
// brokerKeys:
// - Có thể khai báo nhiều từ khóa nhận diện, phân cách bằng dấu |
// - EA tìm trong cả ACCOUNT_COMPANY và ACCOUNT_SERVER.
//
// symbolCandidates:
// - Danh sách symbol theo thứ tự ưu tiên, phân cách bằng dấu |
// - Symbol tồn tại đầu tiên sẽ được chọn.
//
// Hãy sửa danh sách bên dưới theo đúng broker/tài khoản thực tế của bạn.
// Nếu broker không khớp dòng nào, EA mặc định chỉ thử XAUUSD.
//

struct BrokerSymbolConfig
{
   string brokerKeys;
   string symbolCandidates;
};

BrokerSymbolConfig BROKER_CONFIGS[] =
{
   {"Exness",            "XAUUSD|XAUUSDc"},
   {"VantageMarkets",    "XAUUSD|XAUUSD.sc"}
};

const string DEFAULT_SYMBOL_CANDIDATES = "XAUUSD";

//================ GLOBALS =================//

long     g_last_login = -1;
datetime g_last_poll  = 0;

//================ LOG =================//

void Log(const string msg)
{
   if(DEBUG_LOG)
      Print(
         TimeToString(
            TimeCurrent(),
            TIME_DATE | TIME_SECONDS
         ),
         " | ",
         msg
      );
}

//================ STRING UTILS =================//

string Trim(string value)
{
   while(
      StringLen(value) > 0 &&
      (
         value[0] == ' '  ||
         value[0] == '\r' ||
         value[0] == '\n' ||
         value[0] == '\t'
      )
   )
   {
      value = StringSubstr(value, 1);
   }

   while(StringLen(value) > 0)
   {
      int last = StringLen(value) - 1;
      ushort c = value[last];

      if(
         c == ' '  ||
         c == '\r' ||
         c == '\n' ||
         c == '\t'
      )
      {
         value = StringSubstr(value, 0, last);
      }
      else
      {
         break;
      }
   }

   return value;
}

string ToUpperCopy(string value)
{
   StringToUpper(value);
   return value;
}

//================ SYMBOL UTILS =================//

bool SymbolExists(const string symbol)
{
   return (bool)SymbolInfoInteger(
      symbol,
      SYMBOL_EXIST
   );
}

bool IsUsableSymbol(const string symbol)
{
   if(symbol == "")
      return false;

   if(!SymbolExists(symbol))
      return false;

   ENUM_SYMBOL_TRADE_MODE tradeMode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(
         symbol,
         SYMBOL_TRADE_MODE
      );

   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      return false;

   return true;
}

// Kiểm tra brokerInfo có chứa ít nhất một key hay không.
// Ví dụ keys = "IC MARKETS|ICMARKETS".
bool BrokerMatchesAnyKey(
   const string brokerInfo,
   string brokerKeys
)
{
   string keys[];
   ushort separator = StringGetCharacter("|", 0);

   int count = StringSplit(
      brokerKeys,
      separator,
      keys
   );

   if(count <= 0)
      return false;

   for(int i = 0; i < count; i++)
   {
      string key = ToUpperCopy(
         Trim(keys[i])
      );

      if(key == "")
         continue;

      if(StringFind(brokerInfo, key) >= 0)
         return true;
   }

   return false;
}

// Lấy danh sách symbol ưu tiên của broker hiện tại.
// Nếu broker chưa có trong BROKER_CONFIGS thì dùng XAUUSD.
string GetBrokerSymbolCandidates()
{

   string brokerInfo = ToUpperCopy(
      AccountInfoString(ACCOUNT_SERVER)
   );

   int totalConfigs = ArraySize(
      BROKER_CONFIGS
   );

   for(int i = 0; i < totalConfigs; i++)
   {
      if(
         BrokerMatchesAnyKey(
            brokerInfo,
            BROKER_CONFIGS[i].brokerKeys
         )
      )
      {
         return BROKER_CONFIGS[i].symbolCandidates;
      }
   }

   return DEFAULT_SYMBOL_CANDIDATES;
}

// Tìm symbol đầu tiên tồn tại đúng theo thứ tự trong candidates.
// Ví dụ: "XAUUSD|XAUUSD.c|GOLD".
string FindFirstExistingSymbol(string candidates)
{
   string symbols[];
   ushort separator = StringGetCharacter("|", 0);

   int count = StringSplit(
      candidates,
      separator,
      symbols
   );

   if(count <= 0)
      return "";

   for(int i = 0; i < count; i++)
   {
      string symbol = Trim(
         symbols[i]
      );

      if(symbol == "")
         continue;

      if(!IsUsableSymbol(symbol))
         continue;

      ResetLastError();

      if(!SymbolSelect(symbol, true))
      {
         Log(
            StringFormat(
               "SYMBOL SELECT FAILED | symbol=%s | error=%d",
               symbol,
               GetLastError()
            )
         );

         continue;
      }

      return symbol;
   }

   return "";
}

// Telegram luôn gửi XAUUSD.
// EA chọn symbol broker theo BROKER_CONFIGS.
string ResolveSignalSymbol(string incoming)
{
   incoming = ToUpperCopy(
      Trim(incoming)
   );

   if(incoming != "XAUUSD")
   {
      Log(
         "UNSUPPORTED SIGNAL SYMBOL: " +
         incoming
      );

      return "";
   }

   string company = AccountInfoString(
      ACCOUNT_COMPANY
   );

   string server = AccountInfoString(
      ACCOUNT_SERVER
   );

   string candidates =
      GetBrokerSymbolCandidates();

   string resolved =
      FindFirstExistingSymbol(candidates);

   // Broker đã match mapping nhưng danh sách cấu hình không đúng:
   // thử XAUUSD lần cuối để tránh mapping cũ làm hỏng broker vốn dùng XAUUSD.
   if(
      resolved == "" &&
      candidates != DEFAULT_SYMBOL_CANDIDATES
   )
   {
      Log(
         StringFormat(
            "MAPPED SYMBOLS NOT FOUND | candidates=%s -> TRY DEFAULT=%s",
            candidates,
            DEFAULT_SYMBOL_CANDIDATES
         )
      );

      resolved = FindFirstExistingSymbol(
         DEFAULT_SYMBOL_CANDIDATES
      );
   }

   if(resolved == "")
   {
      Log(
         StringFormat(
            "SYMBOL NOT FOUND | company=%s | server=%s | candidates=%s",
            company,
            server,
            candidates
         )
      );

      return "";
   }

   Log(
      StringFormat(
         "SYMBOL RESOLVED | company=%s | server=%s | %s -> %s | candidates=%s",
         company,
         server,
         incoming,
         resolved,
         candidates
      )
   );

   return resolved;
}

//================ SAFE CHART SYMBOL =================//

string PickSafeChartSymbol()
{
   // Ưu tiên đúng symbol vàng theo broker mapping hiện tại
   string goldSymbol = ResolveSignalSymbol("XAUUSD");

   if(goldSymbol != "")
      return goldSymbol;

   // Fallback: lấy symbol đầu tiên trong Market Watch
   int total = SymbolsTotal(false);

   for(int i = 0; i < total; i++)
   {
      string symbol = SymbolName(i, false);

      if(symbol != "" && SymbolExists(symbol))
         return symbol;
   }

   // Fallback cuối: lấy symbol đầu tiên trong toàn bộ broker
   total = SymbolsTotal(true);

   for(int i = 0; i < total; i++)
   {
      string symbol = SymbolName(i, true);

      if(symbol == "")
         continue;

      if(!SymbolExists(symbol))
         continue;

      if(!SymbolSelect(symbol, true))
         continue;

      return symbol;
   }

   return "";
}

void EnsureChartSymbolAlive()
{
   string currentSymbol = Symbol();

   if(SymbolExists(currentSymbol))
      return;

   string safeSymbol = PickSafeChartSymbol();

   if(safeSymbol == "")
   {
      Log("NO SAFE CHART SYMBOL FOUND");
      return;
   }

   ResetLastError();

   bool requested = ChartSetSymbolPeriod(
      0,
      safeSymbol,
      (ENUM_TIMEFRAMES)Period()
   );

   Log(
      StringFormat(
         "CHART SYMBOL RECOVERY | old=%s | new=%s | requested=%d | error=%d",
         currentSymbol,
         safeSymbol,
         (int)requested,
         GetLastError()
      )
   );
}

//================ NORMALIZE =================//

double NormalizePrice(
   const string symbol,
   double price
)
{
   int digits = (int)SymbolInfoInteger(
      symbol,
      SYMBOL_DIGITS
   );

   return NormalizeDouble(
      price,
      digits
   );
}

double NormalizeVolume(
   const string symbol,
   double volume
)
{
   double volumeMin  = 0.0;
   double volumeMax  = 0.0;
   double volumeStep = 0.0;

   SymbolInfoDouble(
      symbol,
      SYMBOL_VOLUME_MIN,
      volumeMin
   );

   SymbolInfoDouble(
      symbol,
      SYMBOL_VOLUME_MAX,
      volumeMax
   );

   SymbolInfoDouble(
      symbol,
      SYMBOL_VOLUME_STEP,
      volumeStep
   );

   if(volumeStep <= 0.0)
      volumeStep = 0.01;

   if(volume < volumeMin)
      volume = volumeMin;

   if(volume > volumeMax)
      volume = volumeMax;

   double normalized =
      MathFloor(volume / volumeStep) *
      volumeStep;

   if(normalized < volumeMin)
      normalized = volumeMin;

   return normalized;
}

//================ HTTP =================//

string HttpResultToString(
   const char &result[]
)
{
   int size = ArraySize(result);

   if(size <= 0)
      return "";

   uchar bytes[];
   ArrayResize(bytes, size);

   for(int i = 0; i < size; i++)
      bytes[i] = (uchar)result[i];

   return CharArrayToString(
      bytes,
      0,
      size,
      CP_UTF8
   );
}

bool HttpPull(
   const string url,
   string &out
)
{
   ResetLastError();

   char data[];
   char result[];

   ArrayResize(data, 0);

   string headers = "";
   string responseHeaders = "";

   int status = WebRequest(
      "GET",
      url,
      headers,
      2000,
      data,
      result,
      responseHeaders
   );

   int errorCode = GetLastError();

   if(DEBUG_LOG)
   {
      Log(
         StringFormat(
            "HTTP status=%d err=%d",
            status,
            errorCode
         )
      );
   }

   if(status != 200)
      return false;

   out = HttpResultToString(result);

   return true;
}

//================ SIMPLE JSON PARSER =================//

string GetString(
   string json,
   string key
)
{
   int keyPosition = StringFind(
      json,
      "\"" + key + "\""
   );

   if(keyPosition < 0)
      return "";

   int colonPosition = StringFind(
      json,
      ":",
      keyPosition
   );

   if(colonPosition < 0)
      return "";

   int quoteStart = StringFind(
      json,
      "\"",
      colonPosition + 1
   );

   if(quoteStart < 0)
      return "";

   quoteStart++;

   int quoteEnd = StringFind(
      json,
      "\"",
      quoteStart
   );

   if(quoteEnd < 0)
      return "";

   return StringSubstr(
      json,
      quoteStart,
      quoteEnd - quoteStart
   );
}

double GetDouble(
   string json,
   string key
)
{
   int keyPosition = StringFind(
      json,
      "\"" + key + "\""
   );

   if(keyPosition < 0)
      return 0.0;

   int colonPosition = StringFind(
      json,
      ":",
      keyPosition
   );

   if(colonPosition < 0)
      return 0.0;

   int valueStart = colonPosition + 1;

   int valueEnd = StringFind(
      json,
      ",",
      valueStart
   );

   if(valueEnd < 0)
   {
      valueEnd = StringFind(
         json,
         "}",
         valueStart
      );
   }

   if(valueEnd < 0)
      return 0.0;

   return StringToDouble(
      StringSubstr(
         json,
         valueStart,
         valueEnd - valueStart
      )
   );
}

int GetArrayCount(
   string json,
   string arrayName
)
{
   int arrayPosition = StringFind(
      json,
      "\"" + arrayName + "\""
   );

   if(arrayPosition < 0)
      return 0;

   int arrayStart = StringFind(
      json,
      "[",
      arrayPosition
   );

   if(arrayStart < 0)
      return 0;

   int arrayEnd = StringFind(
      json,
      "]",
      arrayStart
   );

   if(arrayEnd < 0)
      return 0;

   string block = StringSubstr(
      json,
      arrayStart,
      arrayEnd - arrayStart
   );

   int count = 0;

   for(int i = 0; i < StringLen(block); i++)
   {
      if(block[i] == '{')
         count++;
   }

   return count;
}

double GetArrayDouble(
   string json,
   string arrayName,
   int index,
   string key
)
{
   int arrayPosition = StringFind(
      json,
      "\"" + arrayName + "\""
   );

   if(arrayPosition < 0)
      return 0.0;

   int objectStart = StringFind(
      json,
      "[",
      arrayPosition
   );

   if(objectStart < 0)
      return 0.0;

   for(int i = 0; i <= index; i++)
   {
      objectStart = StringFind(
         json,
         "{",
         objectStart + 1
      );

      if(objectStart < 0)
         return 0.0;
   }

   int objectEnd = StringFind(
      json,
      "}",
      objectStart
   );

   if(objectEnd < 0)
      return 0.0;

   string objectJson = StringSubstr(
      json,
      objectStart,
      objectEnd - objectStart + 1
   );

   return GetDouble(
      objectJson,
      key
   );
}

//================ BREAK EVEN =================//

bool IsBreakEvenValid(
   const string symbol,
   const ENUM_POSITION_TYPE positionType,
   const double openPrice,
   const double currentPrice
)
{
   double point = SymbolInfoDouble(
      symbol,
      SYMBOL_POINT
   );

   int stopsLevel = (int)SymbolInfoInteger(
      symbol,
      SYMBOL_TRADE_STOPS_LEVEL
   );

   double minimumDistance =
      stopsLevel * point;

   if(positionType == POSITION_TYPE_BUY)
   {
      // Với BUY, SL phải nằm dưới giá Bid hiện tại
      return openPrice <= currentPrice - minimumDistance;
   }

   if(positionType == POSITION_TYPE_SELL)
   {
      // Với SELL, SL phải nằm trên giá Ask hiện tại
      return openPrice >= currentPrice + minimumDistance;
   }

   return false;
}

int SetOpenPositionsToBreakEven(
   const string signalSymbol = ""
)
{
   string resolvedSymbol = "";

   if(signalSymbol != "")
   {
      resolvedSymbol =
         ResolveSignalSymbol(signalSymbol);

      if(resolvedSymbol == "")
      {
         Log(
            "SET BE FAILED: cannot resolve symbol " +
            signalSymbol
         );

         return 0;
      }
   }

   int modifiedCount = 0;
   int totalPositions = PositionsTotal();

   Log(
      StringFormat(
         "SET BE START | positions=%d | filterSymbol=%s | magic=%I64d",
         totalPositions,
         resolvedSymbol == "" ? "ALL" : resolvedSymbol,
         MAGIC
      )
   );

   // Duyệt ngược để an toàn khi danh sách position thay đổi
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string positionSymbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      if(
         resolvedSymbol != "" &&
         positionSymbol != resolvedSymbol
      )
      {
         continue;
      }

      ENUM_POSITION_TYPE positionType =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      double openPrice =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      double currentSL =
         PositionGetDouble(
            POSITION_SL
         );

      double currentTP =
         PositionGetDouble(
            POSITION_TP
         );

      int digits =
         (int)SymbolInfoInteger(
            positionSymbol,
            SYMBOL_DIGITS
         );

      openPrice = NormalizeDouble(
         openPrice,
         digits
      );

      MqlTick tick;

      if(!SymbolInfoTick(positionSymbol, tick))
      {
         Log(
            StringFormat(
               "SET BE SKIP | ticket=%I64u | symbol=%s | no tick",
               ticket,
               positionSymbol
            )
         );

         continue;
      }

      double currentPrice =
         positionType == POSITION_TYPE_BUY
         ? tick.bid
         : tick.ask;

      // Đã ở BE rồi thì bỏ qua
      if(
         currentSL > 0.0 &&
         MathAbs(currentSL - openPrice) <
         SymbolInfoDouble(
            positionSymbol,
            SYMBOL_POINT
         ) * 0.5
      )
      {
         Log(
            StringFormat(
               "SET BE SKIP | ticket=%I64u | already BE | sl=%.*f",
               ticket,
               digits,
               currentSL
            )
         );

         continue;
      }

      // Không được kéo SL xấu hơn vị trí hiện tại
      if(
         positionType == POSITION_TYPE_BUY &&
         currentSL > openPrice
      )
      {
         Log(
            StringFormat(
               "SET BE SKIP | ticket=%I64u | BUY SL already above BE | sl=%.*f",
               ticket,
               digits,
               currentSL
            )
         );

         continue;
      }

      if(
         positionType == POSITION_TYPE_SELL &&
         currentSL > 0.0 &&
         currentSL < openPrice
      )
      {
         Log(
            StringFormat(
               "SET BE SKIP | ticket=%I64u | SELL SL already below BE | sl=%.*f",
               ticket,
               digits,
               currentSL
            )
         );

         continue;
      }

      if(
         !IsBreakEvenValid(
            positionSymbol,
            positionType,
            openPrice,
            currentPrice
         )
      )
      {
         Log(
            StringFormat(
               "SET BE SKIP | ticket=%I64u | price not far enough | entry=%.*f | current=%.*f",
               ticket,
               digits,
               openPrice,
               digits,
               currentPrice
            )
         );

         continue;
      }

      ResetLastError();

      bool ok = trade.PositionModify(
         ticket,
         openPrice,
         currentTP
      );

      uint retcode =
         trade.ResultRetcode();

      if(
         !ok ||
         (
            retcode != TRADE_RETCODE_DONE &&
            retcode != TRADE_RETCODE_NO_CHANGES
         )
      )
      {
         Log(
            StringFormat(
               "SET BE FAIL | ticket=%I64u | symbol=%s | ret=%u | %s | error=%d",
               ticket,
               positionSymbol,
               retcode,
               trade.ResultRetcodeDescription(),
               GetLastError()
            )
         );

         continue;
      }

      modifiedCount++;

      Log(
         StringFormat(
            "SET BE OK | ticket=%I64u | symbol=%s | newSL=%.*f | tp=%.*f",
            ticket,
            positionSymbol,
            digits,
            openPrice,
            digits,
            currentTP
         )
      );
   }

   Log(
      StringFormat(
         "SET BE FINISHED | modified=%d",
         modifiedCount
      )
   );

   return modifiedCount;
}

//================ INIT / DEINIT =================//

int OnInit()
{
   if(POLL_SECONDS < 1)
   {
      Print(
         "POLL_SECONDS must be >= 1"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   if(LIMIT_EXPIRY_HOURS < 0)
   {
      Print(
         "LIMIT_EXPIRY_HOURS must be >= 0"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MAGIC);

   g_last_login =
      (long)AccountInfoInteger(
         ACCOUNT_LOGIN
      );

   EnsureChartSymbolAlive();

   EventKillTimer();

   if(!EventSetTimer(POLL_SECONDS))
   {
      Log(
         StringFormat(
            "EVENT TIMER FAILED | error=%d",
            GetLastError()
         )
      );

      return INIT_FAILED;
   }

   Log(
      StringFormat(
         "INIT | login=%I64d | company=%s | server=%s | chartSymbol=%s",
         g_last_login,
         AccountInfoString(ACCOUNT_COMPANY),
         AccountInfoString(ACCOUNT_SERVER),
         Symbol()
      )
   );

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   Log(
      StringFormat(
         "DEINIT | reason=%d",
         reason
      )
   );
}

//================ CHART EVENT =================//
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   EnsureChartSymbolAlive();

   EventKillTimer();
   EventSetTimer(POLL_SECONDS);

   g_last_poll = 0;

   if(DEBUG_LOG)
      Log(StringFormat("CHART EVENT id=%d -> rearm timer", id));
}

//================ TIMER =================//
void OnTimer()
{
   datetime now = TimeCurrent();

   if(now - g_last_poll < POLL_SECONDS)
      return;

   g_last_poll = now;

   long login =
      (long)AccountInfoInteger(
         ACCOUNT_LOGIN
      );

   if(login != g_last_login)
   {
      g_last_login = login;

      trade.SetExpertMagicNumber(MAGIC);

      EnsureChartSymbolAlive();

      Log(
         StringFormat(
            "ACCOUNT CHANGED | login=%I64d | company=%s | server=%s | chartSymbol=%s",
            g_last_login,
            AccountInfoString(ACCOUNT_COMPANY),
            AccountInfoString(ACCOUNT_SERVER),
            Symbol()
         )
      );

      // Không pull ngay trong đúng vòng timer vừa đổi tài khoản.
      return;
   }

   string json = "";

   if(!HttpPull(API, json))
      return;

   json = Trim(json);

   if(StringLen(json) < 2)
      return;

   if(StringFind(json, "{") < 0)
      return;

   string symbol = GetString(
      json,
      "symbol"
   );

   string type = ToUpperCopy(
      Trim(
         GetString(
            json,
            "type"
         )
      )
   );

   double sl = GetDouble(
      json,
      "sl"
   );

   if(
      symbol == "" ||
      type == ""
   )
   {
      Log("PARSE FAIL");
      Log("RAW: " + json);
      return;
   }
   
   //================ SET BREAK EVEN COMMAND =================//

   if(type == "SET_BE")
   {
      int modified =
         SetOpenPositionsToBreakEven(symbol);
   
      Log(
         StringFormat(
            "SET BE COMMAND COMPLETED | modified=%d",
            modified
         )
      );
   
      return;
   }

   string tradeSymbol =
      ResolveSignalSymbol(symbol);

   if(tradeSymbol == "")
   {
      Log(
         "SIGNAL SYMBOL NOT FOUND: " +
         symbol
      );

      return;
   }

   if(tradeSymbol != symbol)
   {
      Log(
         "SIGNAL SYMBOL RESOLVED: " +
         symbol +
         " -> " +
         tradeSymbol
      );
   }

   if(!SymbolSelect(tradeSymbol, true))
   {
      Log(
         StringFormat(
            "SYMBOL SELECT FAILED: %s | error=%d",
            tradeSymbol,
            GetLastError()
         )
      );

      return;
   }

   trade.SetTypeFillingBySymbol(
      tradeSymbol
   );

   int count = GetArrayCount(
      json,
      "orders"
   );

   if(count <= 0)
      return;

   Log(
      StringFormat(
         "SIGNAL %s %s orders=%d",
         tradeSymbol,
         type,
         count
      )
   );

   datetime expiry = 0;

   if(LIMIT_EXPIRY_HOURS > 0)
   {
      expiry = (datetime)(
         TimeCurrent() +
         (long)LIMIT_EXPIRY_HOURS * 3600
      );
   }

   for(int i = 0; i < count; i++)
   {
      double entry = GetArrayDouble(
         json,
         "orders",
         i,
         "entry"
      );

      double takeProfit = GetArrayDouble(
         json,
         "orders",
         i,
         "tp"
      );

      double lot = GetArrayDouble(
         json,
         "orders",
         i,
         "lot"
      );

      if(
         entry <= 0.0 ||
         lot <= 0.0
      )
      {
         Log(
            StringFormat(
               "ORDER SKIPPED | index=%d | entry=%.5f | lot=%.3f",
               i,
               entry,
               lot
            )
         );

         continue;
      }

      entry = NormalizePrice(
         tradeSymbol,
         entry
      );

      takeProfit =
         takeProfit > 0.0
         ? NormalizePrice(
              tradeSymbol,
              takeProfit
           )
         : 0.0;

      double stopLoss =
         sl > 0.0
         ? NormalizePrice(
              tradeSymbol,
              sl
           )
         : 0.0;

      lot = NormalizeVolume(
         tradeSymbol,
         lot
      );

      bool ok = false;

      ENUM_ORDER_TYPE_TIME timeType =
         LIMIT_EXPIRY_HOURS > 0
         ? ORDER_TIME_SPECIFIED
         : ORDER_TIME_GTC;

      datetime expirationTime =
         LIMIT_EXPIRY_HOURS > 0
         ? expiry
         : (datetime)0;

      ResetLastError();

      if(type == "BUY_LIMIT")
      {
         ok = trade.BuyLimit(
            lot,
            entry,
            tradeSymbol,
            stopLoss,
            takeProfit,
            timeType,
            expirationTime,
            COMMENT_TXT
         );

         if(
            !ok &&
            timeType == ORDER_TIME_SPECIFIED
         )
         {
            Log(
               StringFormat(
                  "BUY LIMIT SPECIFIED FAILED -> TRY GTC | ret=%u | %s",
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription()
               )
            );

            ResetLastError();

            ok = trade.BuyLimit(
               lot,
               entry,
               tradeSymbol,
               stopLoss,
               takeProfit,
               ORDER_TIME_GTC,
               0,
               COMMENT_TXT
            );
         }
      }
      else if(type == "SELL_LIMIT")
      {
         ok = trade.SellLimit(
            lot,
            entry,
            tradeSymbol,
            stopLoss,
            takeProfit,
            timeType,
            expirationTime,
            COMMENT_TXT
         );

         if(
            !ok &&
            timeType == ORDER_TIME_SPECIFIED
         )
         {
            Log(
               StringFormat(
                  "SELL LIMIT SPECIFIED FAILED -> TRY GTC | ret=%u | %s",
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription()
               )
            );

            ResetLastError();

            ok = trade.SellLimit(
               lot,
               entry,
               tradeSymbol,
               stopLoss,
               takeProfit,
               ORDER_TIME_GTC,
               0,
               COMMENT_TXT
            );
         }
      }
      else
      {
         Log(
            "UNSUPPORTED ORDER TYPE: " +
            type
         );

         break;
      }

      if(!ok)
      {
         Log(
            StringFormat(
               "TRADE FAIL | index=%d | ret=%u | %s | lastErr=%d",
               i,
               trade.ResultRetcode(),
               trade.ResultRetcodeDescription(),
               GetLastError()
            )
         );
      }
      else
      {
         string expiryText =
            LIMIT_EXPIRY_HOURS > 0
            ? TimeToString(
                 expiry,
                 TIME_DATE | TIME_SECONDS
              )
            : "GTC";

         Log(
            StringFormat(
               "TRADE OK | index=%d | ticket=%I64u | symbol=%s | lot=%.3f | entry=%.5f | expiry=%s",
               i,
               trade.ResultOrder(),
               tradeSymbol,
               lot,
               entry,
               expiryText
            )
         );
      }
   }
}
