#property strict
#property version "4.37"

#include <Trade/Trade.mqh>

CTrade trade;

//================ INPUTS =================//

input string SOCKET_HOST        = "http://locahost";
input int    SOCKET_PORT        = 3002;
input string SOCKET_TOKEN       = "socket_token";
input int    SOCKET_TIMER_MS    = 100;
input int    RECONNECT_SECONDS  = 3;
input long   MAGIC              = 2501153001;
input string COMMENT_TXT        = "";
input bool   DEBUG_LOG          = false;

// Thời hạn của pending LIMIT, tính từ lúc EA nhận tín hiệu, đơn vị PHÚT.
// Đặt 0 để dùng GTC.
input int    LIMIT_EXPIRY_MINUTES = 240;
input double BE_OFFSET_PRICE = 0.1;

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
int      g_socket = INVALID_HANDLE;
string   g_socket_buffer = "";
datetime g_last_connect_attempt = 0;
datetime g_last_heartbeat = 0;
bool     g_chart_recovering = false;
datetime g_last_chart_recovery = 0;
bool     g_pending_chart_recovery = false;
string   g_trade_symbol = "";

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
   // Dùng symbol đã cache; chỉ resolve lại khi khởi động/đổi tài khoản
   // hoặc khi terminal chưa tải xong symbol của tài khoản mới.
   if(IsUsableSymbol(g_trade_symbol))
      return g_trade_symbol;

   g_trade_symbol = ResolveSignalSymbol("XAUUSD");

   if(g_trade_symbol != "")
      return g_trade_symbol;

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
   // Ngăn gọi lồng nhau khi ChartSetSymbolPeriod phát sinh CHARTEVENT_CHART_CHANGE.
   if(g_chart_recovering)
      return;

   string currentSymbol = Symbol();

   // Bình thường chart còn dùng được thì không đụng vào chart.
   // Riêng lúc đổi tài khoản, nếu chart chưa phải symbol vàng đã cache thì vẫn chuyển.
   if(
      IsUsableSymbol(currentSymbol) &&
      (
         !g_pending_chart_recovery ||
         (IsUsableSymbol(g_trade_symbol) && currentSymbol == g_trade_symbol)
      )
   )
   {
      return;
   }

   // Hạn chế thử phục hồi liên tục khi terminal chưa tải xong danh sách symbol.
   datetime now = TimeLocal();

   if(now - g_last_chart_recovery < 2)
      return;

   g_last_chart_recovery = now;
   g_chart_recovering = true;

   string safeSymbol = PickSafeChartSymbol();

   if(safeSymbol == "")
   {
      Log("NO SAFE CHART SYMBOL FOUND");
      g_chart_recovering = false;
      return;
   }

   ResetLastError();

   if(!SymbolSelect(safeSymbol, true))
   {
      Log(
         StringFormat(
            "CHART SYMBOL SELECT FAILED | symbol=%s | error=%d",
            safeSymbol,
            GetLastError()
         )
      );

      g_chart_recovering = false;
      return;
   }

   ResetLastError();

   bool requested = ChartSetSymbolPeriod(
      0,
      safeSymbol,
      (ENUM_TIMEFRAMES)Period()
   );

   int errorCode = GetLastError();

   Log(
      StringFormat(
         "CHART SYMBOL RECOVERY | old=%s | new=%s | requested=%d | error=%d",
         currentSymbol,
         safeSymbol,
         (int)requested,
         errorCode
      )
   );

   if(requested)
      ChartRedraw(0);

   g_chart_recovering = false;
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

//================ TCP SOCKET =================//

void CloseSignalSocket(const string reason = "")
{
   if(g_socket != INVALID_HANDLE)
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
   }

   g_socket_buffer = "";

   if(reason != "")
      Log("SOCKET CLOSED | " + reason);
}

bool SendSocketLine(const string line)
{
   if(g_socket == INVALID_HANDLE || !SocketIsConnected(g_socket))
      return false;

   string payload = line + "\n";
   uchar data[];
   int length = StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;

   if(length <= 0)
      return false;

   ResetLastError();
   int sent = SocketSend(g_socket, data, (uint)length);

   if(sent != length)
   {
      Log(StringFormat("SOCKET SEND FAILED | sent=%d/%d | error=%d", sent, length, GetLastError()));
      CloseSignalSocket("send failed");
      return false;
   }

   return true;
}

bool ConnectSignalSocket()
{
   if(g_socket != INVALID_HANDLE && SocketIsConnected(g_socket))
      return true;

   datetime now = TimeLocal();

   if(now - g_last_connect_attempt < RECONNECT_SECONDS)
      return false;

   g_last_connect_attempt = now;
   CloseSignalSocket();

   ResetLastError();
   g_socket = SocketCreate(SOCKET_DEFAULT);

   if(g_socket == INVALID_HANDLE)
   {
      Log(StringFormat("SOCKET CREATE FAILED | error=%d", GetLastError()));
      return false;
   }

   SocketTimeouts(g_socket, 1000, 1000);

   ResetLastError();

   if(!SocketConnect(g_socket, SOCKET_HOST, (uint)SOCKET_PORT, 2000))
   {
      Log(StringFormat("SOCKET CONNECT FAILED | %s:%d | error=%d", SOCKET_HOST, SOCKET_PORT, GetLastError()));
      CloseSignalSocket();
      return false;
   }

   string hello = StringFormat(
      "{\"type\":\"HELLO\",\"token\":\"%s\",\"login\":%I64d,\"server\":\"%s\"}",
      SOCKET_TOKEN,
      (long)AccountInfoInteger(ACCOUNT_LOGIN),
      AccountInfoString(ACCOUNT_SERVER)
   );

   if(!SendSocketLine(hello))
      return false;

   g_last_heartbeat = TimeLocal();

   Log(StringFormat("SOCKET CONNECTED | %s:%d | login=%I64d", SOCKET_HOST, SOCKET_PORT, (long)AccountInfoInteger(ACCOUNT_LOGIN)));
   return true;
}

string BytesToUtf8(const uchar &bytes[], const int size)
{
   if(size <= 0)
      return "";

   return CharArrayToString(bytes, 0, size, CP_UTF8);
}

void ProcessSignalJson(string json);

void ReadSignalSocket()
{
   if(!ConnectSignalSocket())
      return;

   if(!SocketIsConnected(g_socket))
   {
      CloseSignalSocket("disconnected");
      return;
   }

   uint available = SocketIsReadable(g_socket);

   while(available > 0)
   {
      uchar bytes[];
      int readCount = SocketRead(g_socket, bytes, available, 10);

      if(readCount <= 0)
      {
         CloseSignalSocket("read failed");
         return;
      }

      g_socket_buffer += BytesToUtf8(bytes, readCount);

      if(StringLen(g_socket_buffer) > 1024 * 1024)
      {
         CloseSignalSocket("receive buffer overflow");
         return;
      }

      available = SocketIsReadable(g_socket);
   }

   while(true)
   {
      int newline = StringFind(g_socket_buffer, "\n");

      if(newline < 0)
         break;

      string line = Trim(StringSubstr(g_socket_buffer, 0, newline));
      g_socket_buffer = StringSubstr(g_socket_buffer, newline + 1);

      if(line == "")
         continue;

      if(line == "PING")
      {
         SendSocketLine("PONG");
         continue;
      }

      if(line == "AUTH_OK" || line == "PONG")
         continue;

      if(line == "AUTH_FAILED")
      {
         Log("SOCKET AUTH FAILED: check SOCKET_TOKEN");
         CloseSignalSocket("authentication failed");
         return;
      }

      ProcessSignalJson(line);
   }

   datetime now = TimeLocal();

   if(now - g_last_heartbeat >= 20)
   {
      if(SendSocketLine("PING"))
         g_last_heartbeat = now;
   }
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
      string normalizedSignalSymbol = ToUpperCopy(Trim(signalSymbol));

      if(normalizedSignalSymbol != "XAUUSD")
      {
         Log("SET BE FAILED: unsupported symbol " + signalSymbol);
         return 0;
      }

      resolvedSymbol = g_trade_symbol;

      if(resolvedSymbol == "")
      {
         Log(
            "SET BE FAILED: cached trade symbol is empty for " +
            signalSymbol
         );

         return 0;
      }
   }

   int modifiedCount = 0;
   int totalPositions = PositionsTotal();

   Log(
      StringFormat(
         "SET BE START | positions=%d | filterSymbol=%s",
         totalPositions,
         resolvedSymbol == "" ? "ALL" : resolvedSymbol
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

      
      // Tính mức BE có cộng thêm phí
      
      if(positionType == POSITION_TYPE_BUY)
      {
         openPrice =
            openPrice + BE_OFFSET_PRICE;
      }
      else if(positionType == POSITION_TYPE_SELL)
      {
         openPrice =
            openPrice - BE_OFFSET_PRICE;
      }
      
      openPrice = NormalizeDouble(
         openPrice,
         digits
      );

      // Dùng giá hiện tại của chính position.
      // Không dùng SymbolInfoTick() ở đây vì tick của symbol có thể bị stale
      // sau khi đổi tài khoản / đổi symbol / terminal chưa refresh quote.
      double currentPrice =
         PositionGetDouble(POSITION_PRICE_CURRENT);

      if(currentPrice <= 0.0)
      {
         Log(
            StringFormat(
               "SET BE SKIP | ticket=%I64u | symbol=%s | invalid POSITION_PRICE_CURRENT=%.5f",
               ticket,
               positionSymbol,
               currentPrice
            )
         );

         continue;
      }

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

//================ BULK SL / TP =================//

bool IsSLValid(
   const string symbol,
   const ENUM_POSITION_TYPE positionType,
   const double stopLoss,
   const double currentPrice
)
{
   if(stopLoss <= 0.0)
      return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   int stopsLevel = (int)SymbolInfoInteger(
      symbol,
      SYMBOL_TRADE_STOPS_LEVEL
   );

   int freezeLevel = (int)SymbolInfoInteger(
      symbol,
      SYMBOL_TRADE_FREEZE_LEVEL
   );

   int requiredLevel = MathMax(
      stopsLevel,
      freezeLevel
   );

   double minimumDistance = requiredLevel * point;

   if(positionType == POSITION_TYPE_BUY)
   {
      // SL của BUY phải thấp hơn giá hiện tại của position
      return stopLoss <= currentPrice - minimumDistance;
   }

   if(positionType == POSITION_TYPE_SELL)
   {
      // SL của SELL phải cao hơn giá hiện tại của position
      return stopLoss >= currentPrice + minimumDistance;
   }

   return false;
}

bool IsTPValid(
   const string symbol,
   const ENUM_POSITION_TYPE positionType,
   const double takeProfit,
   const double currentPrice
)
{
   if(takeProfit <= 0.0)
      return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   int stopsLevel = (int)SymbolInfoInteger(
      symbol,
      SYMBOL_TRADE_STOPS_LEVEL
   );

   int freezeLevel = (int)SymbolInfoInteger(
      symbol,
      SYMBOL_TRADE_FREEZE_LEVEL
   );

   int requiredLevel = MathMax(
      stopsLevel,
      freezeLevel
   );

   double minimumDistance = requiredLevel * point;

   if(positionType == POSITION_TYPE_BUY)
   {
      // TP của BUY phải cao hơn giá hiện tại của position
      return takeProfit >= currentPrice + minimumDistance;
   }

   if(positionType == POSITION_TYPE_SELL)
   {
      // TP của SELL phải thấp hơn giá hiện tại của position
      return takeProfit <= currentPrice - minimumDistance;
   }

   return false;
}

int SetBulkPositionLevel(
   const string signalSymbol,
   const string commandType,
   const double requestedPrice
)
{
   string normalizedSignalSymbol = ToUpperCopy(Trim(signalSymbol));

   if(normalizedSignalSymbol != "XAUUSD")
   {
      Log("BULK MODIFY FAILED | unsupported symbol=" + signalSymbol);
      return 0;
   }

   string resolvedSymbol = g_trade_symbol;

   if(resolvedSymbol == "")
   {
      Log(
         "BULK MODIFY FAILED | cached trade symbol is empty for " +
         signalSymbol
      );

      return 0;
   }

   string type = ToUpperCopy(
      Trim(commandType)
   );

   if(
      type != "SET_SL" &&
      type != "SET_TP"
   )
   {
      Log(
         "BULK MODIFY FAILED | unsupported type=" +
         type
      );

      return 0;
   }

   if(requestedPrice <= 0.0)
   {
      Log(
         StringFormat(
            "BULK MODIFY FAILED | invalid price=%.5f",
            requestedPrice
         )
      );

      return 0;
   }

   int modifiedCount = 0;
   int totalPositions = PositionsTotal();

   Log(
      StringFormat(
         "BULK MODIFY START | type=%s | symbol=%s | price=%.5f | positions=%d",
         type,
         resolvedSymbol,
         requestedPrice,
         totalPositions
      )
   );

   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string positionSymbol = PositionGetString(
         POSITION_SYMBOL
      );

      if(positionSymbol != resolvedSymbol)
         continue;

      ENUM_POSITION_TYPE positionType =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      double currentSL = PositionGetDouble(
         POSITION_SL
      );

      double currentTP = PositionGetDouble(
         POSITION_TP
      );

      int digits = (int)SymbolInfoInteger(
         positionSymbol,
         SYMBOL_DIGITS
      );

      double newPrice = NormalizeDouble(
         requestedPrice,
         digits
      );

      double newSL = currentSL;
      double newTP = currentTP;

      // Dùng giá hiện tại của chính position cho SET_SL / SET_TP.
      // Không dùng SymbolInfoTick() để tránh Bid/Ask stale.
      double positionCurrent =
         PositionGetDouble(POSITION_PRICE_CURRENT);

      if(positionCurrent <= 0.0)
      {
         Log(
            StringFormat(
               "BULK MODIFY SKIP | ticket=%I64u | invalid POSITION_PRICE_CURRENT=%.5f",
               ticket,
               positionCurrent
            )
         );

         continue;
      }

      if(type == "SET_SL")
      {
         if(
            currentSL > 0.0 &&
            MathAbs(currentSL - newPrice) <
            SymbolInfoDouble(
               positionSymbol,
               SYMBOL_POINT
            ) * 0.5
         )
         {
            Log(
               StringFormat(
                  "SET SL SKIP | ticket=%I64u | already set | sl=%.*f",
                  ticket,
                  digits,
                  currentSL
               )
            );

            continue;
         }

         if(
            !IsSLValid(
               positionSymbol,
               positionType,
               newPrice,
               positionCurrent
            )
         )
         {
            Log(
               StringFormat(
                  "SET SL SKIP | ticket=%I64u | invalid level | side=%s | requested=%.*f | current=%.*f",
                  ticket,
                  positionType == POSITION_TYPE_BUY ? "BUY" : "SELL",
                  digits,
                  newPrice,
                  digits,
                  positionCurrent
               )
            );

            continue;
         }

         newSL = newPrice;
      }
      else if(type == "SET_TP")
      {
         if(
            currentTP > 0.0 &&
            MathAbs(currentTP - newPrice) <
            SymbolInfoDouble(
               positionSymbol,
               SYMBOL_POINT
            ) * 0.5
         )
         {
            Log(
               StringFormat(
                  "SET TP SKIP | ticket=%I64u | already set | tp=%.*f",
                  ticket,
                  digits,
                  currentTP
               )
            );

            continue;
         }

         if(
            !IsTPValid(
               positionSymbol,
               positionType,
               newPrice,
               positionCurrent
            )
         )
         {
            Log(
               StringFormat(
                  "SET TP SKIP | ticket=%I64u | invalid level | side=%s | requested=%.*f | current=%.*f",
                  ticket,
                  positionType == POSITION_TYPE_BUY ? "BUY" : "SELL",
                  digits,
                  newPrice,
                  digits,
                  positionCurrent
               )
            );

            continue;
         }

         newTP = newPrice;
      }

      ResetLastError();

      bool ok = trade.PositionModify(
         ticket,
         newSL,
         newTP
      );

      uint retcode = trade.ResultRetcode();

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
               "BULK MODIFY FAIL | ticket=%I64u | type=%s | ret=%u | %s | error=%d",
               ticket,
               type,
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
            "BULK MODIFY OK | ticket=%I64u | symbol=%s | type=%s | sl=%.*f | tp=%.*f",
            ticket,
            positionSymbol,
            type,
            digits,
            newSL,
            digits,
            newTP
         )
      );
   }

   Log(
      StringFormat(
         "BULK MODIFY FINISHED | type=%s | modified=%d",
         type,
         modifiedCount
      )
   );

   return modifiedCount;
}

//================ INIT / DEINIT =================//

int OnInit()
{
   if(SOCKET_PORT <= 0 || SOCKET_PORT > 65535)
   {
      Print("SOCKET_PORT must be between 1 and 65535");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SOCKET_TIMER_MS < 20)
   {
      Print("SOCKET_TIMER_MS must be >= 20");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(RECONNECT_SECONDS < 1)
   {
      Print("RECONNECT_SECONDS must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(LIMIT_EXPIRY_MINUTES < 0)
   {
      Print("LIMIT_EXPIRY_MINUTES must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MAGIC);

   g_last_login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   g_trade_symbol = ResolveSignalSymbol("XAUUSD");

   EnsureChartSymbolAlive();
   g_pending_chart_recovery = !IsUsableSymbol(Symbol());

   EventKillTimer();

   if(!EventSetMillisecondTimer(SOCKET_TIMER_MS))
   {
      Log(StringFormat("EVENT TIMER FAILED | error=%d", GetLastError()));
      return INIT_FAILED;
   }

   Log(
      StringFormat(
         "INIT SOCKET | login=%I64d | server=%s | chartSymbol=%s | tradeSymbol=%s",
         g_last_login,
         AccountInfoString(ACCOUNT_SERVER),
         Symbol(),
         g_trade_symbol
      )
   );

   ConnectSignalSocket();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   CloseSignalSocket("EA deinit");

   Log(StringFormat("DEINIT | reason=%d", reason));
}

//================ CHART EVENT =================//

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   // Chỉ quan tâm khi trạng thái chart thay đổi.
   if(id != CHARTEVENT_CHART_CHANGE)
      return;

   // M15 hoặc timeframe khác chỉ phát sinh event, nhưng symbol vẫn hợp lệ thì bỏ qua.
   if(IsUsableSymbol(Symbol()))
      return;

   g_pending_chart_recovery = true;
   EnsureChartSymbolAlive();
}

//================ TIMER =================//

void OnTimer()
{
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);

   if(login != g_last_login)
   {
      g_last_login = login;
      trade.SetExpertMagicNumber(MAGIC);
      g_trade_symbol = "";
      g_pending_chart_recovery = true;
      CloseSignalSocket("account changed");
      g_last_connect_attempt = 0;

      Log(
         StringFormat(
            "ACCOUNT CHANGED | login=%I64d | company=%s | server=%s | oldChartSymbol=%s",
            g_last_login,
            AccountInfoString(ACCOUNT_COMPANY),
            AccountInfoString(ACCOUNT_SERVER),
            Symbol()
         )
      );

      return;
   }

   // Sau khi đổi tài khoản, terminal có thể cần vài vòng timer để tải symbol mới.
   // Resolve được giới hạn bởi khóa 2 giây trong EnsureChartSymbolAlive().
   if(g_pending_chart_recovery)
   {
      EnsureChartSymbolAlive();

      if(
         IsUsableSymbol(g_trade_symbol) &&
         IsUsableSymbol(Symbol()) &&
         Symbol() == g_trade_symbol
      )
      {
         g_pending_chart_recovery = false;

         Log(
            StringFormat(
               "CHART RECOVERY COMPLETED | chartSymbol=%s | tradeSymbol=%s",
               Symbol(),
               g_trade_symbol
            )
         );
      }
   }

   ReadSignalSocket();
}

void ProcessSignalJson(string json)
{
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

   //================ SET SL HÀNG LOẠT =================//

   if(type == "SET_SL")
   {
      double price = GetDouble(
         json,
         "price"
      );

      int modified = SetBulkPositionLevel(
         symbol,
         type,
         price
      );

      Log(
         StringFormat(
            "SET SL COMMAND COMPLETED | price=%.5f | modified=%d",
            price,
            modified
         )
      );

      return;
   }

   //================ SET TP HÀNG LOẠT =================//

   if(type == "SET_TP")
   {
      double price = GetDouble(
         json,
         "price"
      );

      int modified = SetBulkPositionLevel(
         symbol,
         type,
         price
      );

      Log(
         StringFormat(
            "SET TP COMMAND COMPLETED | price=%.5f | modified=%d",
            price,
            modified
         )
      );

      return;
   }

   string normalizedSignalSymbol = ToUpperCopy(Trim(symbol));

   if(normalizedSignalSymbol != "XAUUSD")
   {
      Log("UNSUPPORTED SIGNAL SYMBOL: " + symbol);
      return;
   }

   string tradeSymbol = g_trade_symbol;

   if(tradeSymbol == "")
   {
      Log(
         "CACHED TRADE SYMBOL IS EMPTY: " +
         symbol
      );

      return;
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

   if(LIMIT_EXPIRY_MINUTES > 0)
   {
      expiry = (datetime)(
         TimeCurrent() +
         (long)LIMIT_EXPIRY_MINUTES * 60
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
         LIMIT_EXPIRY_MINUTES > 0
         ? ORDER_TIME_SPECIFIED
         : ORDER_TIME_GTC;

      datetime expirationTime =
         LIMIT_EXPIRY_MINUTES > 0
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
            LIMIT_EXPIRY_MINUTES > 0
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
