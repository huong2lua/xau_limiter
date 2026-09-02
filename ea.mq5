#property strict
#property version "5.01"

#include <Trade/Trade.mqh>

CTrade trade;

//================ INPUTS =================//

input string SOCKET_HOST          = "http://localhost";
input int    SOCKET_PORT          = 3002;
input string SOCKET_TOKEN         = "phone_token";
input int    SOCKET_TIMER_MS      = 100;
input int    RECONNECT_SECONDS    = 3;
input long   MAGIC                = 123456789;
input string COMMENT_TXT          = "";
input bool   DEBUG_LOG            = false;

// Thời hạn pending LIMIT tính từ lúc nhận tín hiệu (phút). 0 = GTC.
input int    LIMIT_EXPIRY_MINUTES = 240;
input double BE_OFFSET_PRICE      = 0.1;

//================ SYMBOL CANDIDATES =================//
//
// Thay cho BROKER_CONFIGS: không cần biết broker nào, chỉ cần dò symbol vàng
// theo thứ tự ưu tiên, sau đó quét Market Watch tìm symbol bắt đầu bằng "XAU".
//

const string SIGNAL_SYMBOL = "XAUUSD";

const string GOLD_CANDIDATES[] =
{
   "XAUUSD", "XAUUSDc", "XAUUSD.sc", "XAUUSD.c",
   "XAUUSDm", "XAUUSD.a", "XAUUSD.v", "GOLD"
};

//================ GLOBALS =================//

long     g_last_login          = -1;
int      g_socket              = INVALID_HANDLE;
string   g_socket_buffer       = "";
datetime g_last_connect_attempt = 0;
datetime g_last_heartbeat      = 0;
datetime g_last_symbol_attempt = 0;
string   g_trade_symbol        = "";

bool     g_chart_recovering    = false;
bool     g_pending_chart       = false;
datetime g_last_chart_recovery = 0;

//================ LOG / STRING =================//

void Log(const string msg)
{
   if(DEBUG_LOG)
      Print(TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), " | ", msg);
}

string Trim(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   return value;
}

string ToUpperCopy(string value)
{
   StringToUpper(value);
   return value;
}

//================ SYMBOL UTILS =================//

bool IsUsableSymbol(const string symbol)
{
   if(symbol == "")
      return false;

   if(!(bool)SymbolInfoInteger(symbol, SYMBOL_EXIST))
      return false;

   return (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE)
          != SYMBOL_TRADE_MODE_DISABLED;
}

bool IsSignalSymbol(const string symbol)
{
   return ToUpperCopy(Trim(symbol)) == SIGNAL_SYMBOL;
}

bool TrySelect(const string symbol)
{
   if(!IsUsableSymbol(symbol))
      return false;

   ResetLastError();

   if(SymbolSelect(symbol, true))
      return true;

   Log(StringFormat("SYMBOL SELECT FAILED | symbol=%s | error=%d", symbol, GetLastError()));
   return false;
}

// Telegram luôn gửi XAUUSD. EA tự dò symbol vàng của broker hiện tại.
string ResolveGoldSymbol()
{
   for(int i = 0; i < ArraySize(GOLD_CANDIDATES); i++)
      if(TrySelect(GOLD_CANDIDATES[i]))
         return GOLD_CANDIDATES[i];

   // Dự phòng: quét toàn bộ symbol của broker, lấy cái bắt đầu bằng "XAU".
   int total = SymbolsTotal(true);

   for(int i = 0; i < total; i++)
   {
      string symbol = SymbolName(i, true);

      if(StringFind(ToUpperCopy(symbol), "XAU") != 0)
         continue;

      if(TrySelect(symbol))
         return symbol;
   }

   Log(StringFormat("GOLD SYMBOL NOT FOUND | company=%s | server=%s",
                    AccountInfoString(ACCOUNT_COMPANY),
                    AccountInfoString(ACCOUNT_SERVER)));

   return "";
}

//================ CHART SYMBOL =================//

// Ưu tiên symbol vàng đã cache; nếu không có thì lấy symbol dùng được đầu tiên
// (Market Watch trước, sau đó toàn bộ danh sách broker).
string PickChartSymbol()
{
   if(IsUsableSymbol(g_trade_symbol))
      return g_trade_symbol;

   g_trade_symbol = ResolveGoldSymbol();

   if(g_trade_symbol != "")
      return g_trade_symbol;

   for(int pass = 0; pass < 2; pass++)
   {
      bool selectedOnly = (pass == 0);   // 0 = Market Watch, 1 = toàn bộ broker
      int  total        = SymbolsTotal(selectedOnly);

      for(int i = 0; i < total; i++)
      {
         string symbol = SymbolName(i, selectedOnly);

         if(TrySelect(symbol))
            return symbol;
      }
   }

   return "";
}

// Giữ chart luôn ở một symbol hợp lệ, và đưa chart về symbol vàng
// khi khởi động / đổi tài khoản (g_pending_chart = true).
void SyncChartSymbol()
{
   // Ngăn gọi lồng nhau khi ChartSetSymbolPeriod phát sinh CHARTEVENT_CHART_CHANGE.
   if(g_chart_recovering)
      return;

   string chartSymbol = Symbol();

   bool needGoldChart = g_pending_chart &&
                        !(IsUsableSymbol(g_trade_symbol) && chartSymbol == g_trade_symbol);

   // Chart còn dùng được và không phải lúc chuyển về vàng thì không đụng vào chart.
   if(IsUsableSymbol(chartSymbol) && !needGoldChart)
      return;

   // Hạn chế thử liên tục khi terminal chưa tải xong danh sách symbol.
   datetime now = TimeLocal();

   if(now - g_last_chart_recovery < 2)
      return;

   g_last_chart_recovery = now;
   g_chart_recovering    = true;

   string safeSymbol = PickChartSymbol();

   if(safeSymbol == "")
   {
      Log("NO SAFE CHART SYMBOL FOUND");
      g_chart_recovering = false;
      return;
   }

   ResetLastError();

   bool requested = ChartSetSymbolPeriod(0, safeSymbol, (ENUM_TIMEFRAMES)Period());
   int  errorCode = GetLastError();

   Log(StringFormat("CHART SYMBOL RECOVERY | old=%s | new=%s | requested=%d | error=%d",
                    chartSymbol, safeSymbol, (int)requested, errorCode));

   if(requested)
      ChartRedraw(0);

   g_chart_recovering = false;
}

//================ NORMALIZE =================//

double NormalizePrice(const string symbol, const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

double NormalizeVolume(const string symbol, double volume)
{
   double volumeMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volumeMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(volumeStep <= 0.0)
      volumeStep = 0.01;

   volume = MathMin(MathMax(volume, volumeMin), volumeMax);

   double normalized = MathFloor(volume / volumeStep) * volumeStep;

   return (normalized < volumeMin) ? volumeMin : normalized;
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

   uchar data[];
   int length = StringToCharArray(line + "\n", data, 0, WHOLE_ARRAY, CP_UTF8) - 1;

   if(length <= 0)
      return false;

   ResetLastError();
   int sent = SocketSend(g_socket, data, (uint)length);

   if(sent != length)
   {
      Log(StringFormat("SOCKET SEND FAILED | sent=%d/%d | error=%d",
                       sent, length, GetLastError()));
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
      Log(StringFormat("SOCKET CONNECT FAILED | %s:%d | error=%d",
                       SOCKET_HOST, SOCKET_PORT, GetLastError()));
      CloseSignalSocket();
      return false;
   }

   string hello = StringFormat(
      "{\"type\":\"HELLO\",\"token\":\"%s\",\"login\":%I64d,\"server\":\"%s\"}",
      SOCKET_TOKEN,
      (long)AccountInfoInteger(ACCOUNT_LOGIN),
      AccountInfoString(ACCOUNT_SERVER));

   if(!SendSocketLine(hello))
      return false;

   g_last_heartbeat = TimeLocal();

   Log(StringFormat("SOCKET CONNECTED | %s:%d | login=%I64d",
                    SOCKET_HOST, SOCKET_PORT,
                    (long)AccountInfoInteger(ACCOUNT_LOGIN)));

   return true;
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

      g_socket_buffer += CharArrayToString(bytes, 0, readCount, CP_UTF8);

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

      if(line == "" || line == "AUTH_OK" || line == "PONG")
         continue;

      if(line == "PING")
      {
         SendSocketLine("PONG");
         continue;
      }

      if(line == "AUTH_FAILED")
      {
         Log("SOCKET AUTH FAILED: check SOCKET_TOKEN");
         CloseSignalSocket("authentication failed");
         return;
      }

      ProcessSignalJson(line);
   }

   datetime now = TimeLocal();

   if(now - g_last_heartbeat >= 20 && SendSocketLine("PING"))
      g_last_heartbeat = now;
}

//================ SIMPLE JSON PARSER =================//

string GetString(string json, string key)
{
   int keyPosition = StringFind(json, "\"" + key + "\"");
   if(keyPosition < 0)
      return "";

   int colonPosition = StringFind(json, ":", keyPosition);
   if(colonPosition < 0)
      return "";

   int quoteStart = StringFind(json, "\"", colonPosition + 1);
   if(quoteStart < 0)
      return "";

   quoteStart++;

   int quoteEnd = StringFind(json, "\"", quoteStart);
   if(quoteEnd < 0)
      return "";

   return StringSubstr(json, quoteStart, quoteEnd - quoteStart);
}

double GetDouble(string json, string key)
{
   int keyPosition = StringFind(json, "\"" + key + "\"");
   if(keyPosition < 0)
      return 0.0;

   int colonPosition = StringFind(json, ":", keyPosition);
   if(colonPosition < 0)
      return 0.0;

   int valueStart = colonPosition + 1;
   int valueEnd   = StringFind(json, ",", valueStart);

   if(valueEnd < 0)
      valueEnd = StringFind(json, "}", valueStart);

   if(valueEnd < 0)
      return 0.0;

   return StringToDouble(StringSubstr(json, valueStart, valueEnd - valueStart));
}

int GetArrayCount(string json, string arrayName)
{
   int arrayPosition = StringFind(json, "\"" + arrayName + "\"");
   if(arrayPosition < 0)
      return 0;

   int arrayStart = StringFind(json, "[", arrayPosition);
   if(arrayStart < 0)
      return 0;

   int arrayEnd = StringFind(json, "]", arrayStart);
   if(arrayEnd < 0)
      return 0;

   string block = StringSubstr(json, arrayStart, arrayEnd - arrayStart);
   int count = 0;

   for(int i = 0; i < StringLen(block); i++)
      if(block[i] == '{')
         count++;

   return count;
}

double GetArrayDouble(string json, string arrayName, int index, string key)
{
   int arrayPosition = StringFind(json, "\"" + arrayName + "\"");
   if(arrayPosition < 0)
      return 0.0;

   int objectStart = StringFind(json, "[", arrayPosition);
   if(objectStart < 0)
      return 0.0;

   for(int i = 0; i <= index; i++)
   {
      objectStart = StringFind(json, "{", objectStart + 1);

      if(objectStart < 0)
         return 0.0;
   }

   int objectEnd = StringFind(json, "}", objectStart);
   if(objectEnd < 0)
      return 0.0;

   return GetDouble(StringSubstr(json, objectStart, objectEnd - objectStart + 1), key);
}

//================ LEVEL VALIDATION =================//
//
// Gộp IsBreakEvenValid + IsSLValid + IsTPValid.
// isStop = true  -> mức đang xét là SL (gồm cả BE).
// isStop = false -> mức đang xét là TP.
// useFreeze = false giữ đúng hành vi cũ của BE (chỉ dùng STOPS_LEVEL).
//

bool IsLevelValid(const string symbol,
                  const ENUM_POSITION_TYPE side,
                  const bool isStop,
                  const double level,
                  const double currentPrice,
                  const bool useFreeze)
{
   if(level <= 0.0)
      return false;

   int requiredLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(useFreeze)
      requiredLevel = MathMax(requiredLevel,
                              (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL));

   double minimumDistance = requiredLevel * SymbolInfoDouble(symbol, SYMBOL_POINT);

   // BUY-SL và SELL-TP phải nằm dưới giá hiện tại; hai trường hợp còn lại nằm trên.
   bool mustBeBelow = ((side == POSITION_TYPE_BUY) == isStop);

   return mustBeBelow ? (level <= currentPrice - minimumDistance)
                      : (level >= currentPrice + minimumDistance);
}

//================ SET_BE / SET_SL / SET_TP =================//
//
// Gộp SetOpenPositionsToBreakEven() + SetBulkPositionLevel().
//

int ApplyLevel(const string signalSymbol,
               const string commandType,
               const double requestedPrice)
{
   string type = ToUpperCopy(Trim(commandType));

   bool isBE = (type == "SET_BE");
   bool isSL = (type == "SET_SL");
   bool isTP = (type == "SET_TP");

   if(!isBE && !isSL && !isTP)
   {
      Log("MODIFY FAILED | unsupported type=" + type);
      return 0;
   }

   if(!IsSignalSymbol(signalSymbol))
   {
      Log("MODIFY FAILED | unsupported symbol=" + signalSymbol);
      return 0;
   }

   if(g_trade_symbol == "")
   {
      Log("MODIFY FAILED | cached trade symbol is empty");
      return 0;
   }

   if(!isBE && requestedPrice <= 0.0)
   {
      Log(StringFormat("MODIFY FAILED | type=%s | invalid price=%.5f", type, requestedPrice));
      return 0;
   }

   string symbol    = g_trade_symbol;
   int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double halfPoint = SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.5;
   bool   touchesSL = (isBE || isSL);

   int modifiedCount = 0;
   int totalPositions = PositionsTotal();

   Log(StringFormat("MODIFY START | type=%s | symbol=%s | price=%.5f | positions=%d",
                    type, symbol, requestedPrice, totalPositions));

   // Duyệt ngược để an toàn khi danh sách position thay đổi.
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      // Dùng giá hiện tại của chính position, không dùng SymbolInfoTick()
      // vì tick có thể stale sau khi đổi tài khoản / symbol.
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);

      if(currentPrice <= 0.0)
      {
         Log(StringFormat("MODIFY SKIP | ticket=%I64u | invalid POSITION_PRICE_CURRENT=%.5f",
                          ticket, currentPrice));
         continue;
      }

      // Mức đích: BE tính từ giá mở + phí, còn lại lấy theo giá yêu cầu.
      double target = requestedPrice;

      if(isBE)
      {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

         target = (side == POSITION_TYPE_BUY)
                  ? openPrice + BE_OFFSET_PRICE
                  : openPrice - BE_OFFSET_PRICE;
      }

      target = NormalizeDouble(target, digits);

      // Đã đặt đúng mức đó rồi thì bỏ qua.
      double existing = touchesSL ? currentSL : currentTP;

      if(existing > 0.0 && MathAbs(existing - target) < halfPoint)
      {
         Log(StringFormat("MODIFY SKIP | ticket=%I64u | type=%s | already set | level=%.*f",
                          ticket, type, digits, existing));
         continue;
      }

      // BE: không được kéo SL về vị trí xấu hơn hiện tại.
      if(isBE)
      {
         if(side == POSITION_TYPE_BUY && currentSL > target)
         {
            Log(StringFormat("SET BE SKIP | ticket=%I64u | BUY SL already above BE | sl=%.*f",
                             ticket, digits, currentSL));
            continue;
         }

         if(side == POSITION_TYPE_SELL && currentSL > 0.0 && currentSL < target)
         {
            Log(StringFormat("SET BE SKIP | ticket=%I64u | SELL SL already below BE | sl=%.*f",
                             ticket, digits, currentSL));
            continue;
         }
      }

      if(!IsLevelValid(symbol, side, touchesSL, target, currentPrice, !isBE))
      {
         Log(StringFormat("MODIFY SKIP | ticket=%I64u | type=%s | invalid level | side=%s | requested=%.*f | current=%.*f",
                          ticket, type,
                          side == POSITION_TYPE_BUY ? "BUY" : "SELL",
                          digits, target, digits, currentPrice));
         continue;
      }

      double newSL = touchesSL ? target : currentSL;
      double newTP = touchesSL ? currentTP : target;

      ResetLastError();

      bool ok = trade.PositionModify(ticket, newSL, newTP);
      uint retcode = trade.ResultRetcode();

      if(!ok || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_NO_CHANGES))
      {
         Log(StringFormat("MODIFY FAIL | ticket=%I64u | type=%s | ret=%u | %s | error=%d",
                          ticket, type, retcode,
                          trade.ResultRetcodeDescription(), GetLastError()));
         continue;
      }

      modifiedCount++;

      Log(StringFormat("MODIFY OK | ticket=%I64u | symbol=%s | type=%s | sl=%.*f | tp=%.*f",
                       ticket, symbol, type, digits, newSL, digits, newTP));
   }

   Log(StringFormat("MODIFY FINISHED | type=%s | modified=%d", type, modifiedCount));

   return modifiedCount;
}

//================ PLACE LIMIT =================//
//
// Gộp 2 nhánh BUY_LIMIT / SELL_LIMIT, gồm cả fallback GTC.
//

bool PlaceLimit(const bool isBuy,
                const string symbol,
                const double lot,
                const double entry,
                const double stopLoss,
                const double takeProfit,
                const datetime expiry)
{
   ENUM_ORDER_TYPE_TIME timeType =
      (LIMIT_EXPIRY_MINUTES > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   datetime expirationTime = (LIMIT_EXPIRY_MINUTES > 0) ? expiry : (datetime)0;

   ResetLastError();

   bool ok = isBuy
      ? trade.BuyLimit(lot, entry, symbol, stopLoss, takeProfit, timeType, expirationTime, COMMENT_TXT)
      : trade.SellLimit(lot, entry, symbol, stopLoss, takeProfit, timeType, expirationTime, COMMENT_TXT);

   if(!ok && timeType == ORDER_TIME_SPECIFIED)
   {
      Log(StringFormat("%s LIMIT SPECIFIED FAILED -> TRY GTC | ret=%u | %s",
                       isBuy ? "BUY" : "SELL",
                       trade.ResultRetcode(),
                       trade.ResultRetcodeDescription()));

      ResetLastError();

      ok = isBuy
         ? trade.BuyLimit(lot, entry, symbol, stopLoss, takeProfit, ORDER_TIME_GTC, 0, COMMENT_TXT)
         : trade.SellLimit(lot, entry, symbol, stopLoss, takeProfit, ORDER_TIME_GTC, 0, COMMENT_TXT);
   }

   return ok;
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

   g_last_login   = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   g_trade_symbol = ResolveGoldSymbol();

   g_pending_chart = true;
   SyncChartSymbol();

   EventKillTimer();

   if(!EventSetMillisecondTimer(SOCKET_TIMER_MS))
   {
      Log(StringFormat("EVENT TIMER FAILED | error=%d", GetLastError()));
      return INIT_FAILED;
   }

   Log(StringFormat("INIT SOCKET | login=%I64d | server=%s | chartSymbol=%s | tradeSymbol=%s",
                    g_last_login,
                    AccountInfoString(ACCOUNT_SERVER),
                    Symbol(),
                    g_trade_symbol));

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

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_CHART_CHANGE)
      return;

   // Đổi timeframe / zoom vẫn phát event; symbol còn hợp lệ thì bỏ qua.
   if(IsUsableSymbol(Symbol()))
      return;

   g_pending_chart = true;
   SyncChartSymbol();
}

//================ TIMER =================//

void OnTimer()
{
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);

   if(login != g_last_login)
   {
      g_last_login = login;
      trade.SetExpertMagicNumber(MAGIC);

      g_trade_symbol        = "";
      g_last_symbol_attempt = 0;
      g_last_connect_attempt = 0;
      g_pending_chart       = true;

      CloseSignalSocket("account changed");

      Log(StringFormat("ACCOUNT CHANGED | login=%I64d | company=%s | server=%s | oldChartSymbol=%s",
                       g_last_login,
                       AccountInfoString(ACCOUNT_COMPANY),
                       AccountInfoString(ACCOUNT_SERVER),
                       Symbol()));

      return;
   }

   // Sau khi đổi tài khoản, terminal cần vài vòng timer để tải symbol mới.
   // Thử lại tối đa mỗi 2 giây.
   if(!IsUsableSymbol(g_trade_symbol))
   {
      datetime now = TimeLocal();

      if(now - g_last_symbol_attempt >= 2)
      {
         g_last_symbol_attempt = now;
         g_trade_symbol = ResolveGoldSymbol();

         if(g_trade_symbol != "")
            Log("TRADE SYMBOL RESOLVED | " + g_trade_symbol);
      }
   }

   // Giữ chart hợp lệ / kéo chart về symbol vàng. Guard bên trong tự thoát nhanh.
   SyncChartSymbol();

   if(g_pending_chart &&
      IsUsableSymbol(g_trade_symbol) &&
      Symbol() == g_trade_symbol)
   {
      g_pending_chart = false;

      Log(StringFormat("CHART RECOVERY COMPLETED | chartSymbol=%s | tradeSymbol=%s",
                       Symbol(), g_trade_symbol));
   }

   ReadSignalSocket();
}

//================ SIGNAL DISPATCH =================//

void ProcessSignalJson(string json)
{
   json = Trim(json);

   if(StringLen(json) < 2 || StringFind(json, "{") < 0)
      return;

   string symbol = GetString(json, "symbol");
   string type   = ToUpperCopy(Trim(GetString(json, "type")));

   if(symbol == "" || type == "")
   {
      Log("PARSE FAIL");
      Log("RAW: " + json);
      return;
   }

   //---- Lệnh sửa mức: SET_BE / SET_SL / SET_TP ----//

   if(type == "SET_BE" || type == "SET_SL" || type == "SET_TP")
   {
      double price = (type == "SET_BE") ? 0.0 : GetDouble(json, "price");
      int modified = ApplyLevel(symbol, type, price);

      Log(StringFormat("%s COMMAND COMPLETED | price=%.5f | modified=%d",
                       type, price, modified));
      return;
   }

   //---- Lệnh vào thị trường ----//

   if(type != "BUY_LIMIT" && type != "SELL_LIMIT")
   {
      Log("UNSUPPORTED ORDER TYPE: " + type);
      return;
   }

   if(!IsSignalSymbol(symbol))
   {
      Log("UNSUPPORTED SIGNAL SYMBOL: " + symbol);
      return;
   }

   string tradeSymbol = g_trade_symbol;

   if(tradeSymbol == "")
   {
      Log("CACHED TRADE SYMBOL IS EMPTY: " + symbol);
      return;
   }

   if(!SymbolSelect(tradeSymbol, true))
   {
      Log(StringFormat("SYMBOL SELECT FAILED: %s | error=%d",
                       tradeSymbol, GetLastError()));
      return;
   }

   trade.SetTypeFillingBySymbol(tradeSymbol);

   int count = GetArrayCount(json, "orders");

   if(count <= 0)
      return;

   bool   isBuy = (type == "BUY_LIMIT");
   double sl    = GetDouble(json, "sl");

   double stopLoss = (sl > 0.0) ? NormalizePrice(tradeSymbol, sl) : 0.0;

   datetime expiry = 0;

   if(LIMIT_EXPIRY_MINUTES > 0)
      expiry = (datetime)(TimeCurrent() + (long)LIMIT_EXPIRY_MINUTES * 60);

   string expiryText = (LIMIT_EXPIRY_MINUTES > 0)
      ? TimeToString(expiry, TIME_DATE | TIME_SECONDS)
      : "GTC";

   Log(StringFormat("SIGNAL %s %s orders=%d", tradeSymbol, type, count));

   for(int i = 0; i < count; i++)
   {
      double entry      = GetArrayDouble(json, "orders", i, "entry");
      double takeProfit = GetArrayDouble(json, "orders", i, "tp");
      double lot        = GetArrayDouble(json, "orders", i, "lot");

      if(entry <= 0.0 || lot <= 0.0)
      {
         Log(StringFormat("ORDER SKIPPED | index=%d | entry=%.5f | lot=%.3f",
                          i, entry, lot));
         continue;
      }

      entry      = NormalizePrice(tradeSymbol, entry);
      takeProfit = (takeProfit > 0.0) ? NormalizePrice(tradeSymbol, takeProfit) : 0.0;
      lot        = NormalizeVolume(tradeSymbol, lot);

      if(!PlaceLimit(isBuy, tradeSymbol, lot, entry, stopLoss, takeProfit, expiry))
      {
         Log(StringFormat("TRADE FAIL | index=%d | ret=%u | %s | lastErr=%d",
                          i, trade.ResultRetcode(),
                          trade.ResultRetcodeDescription(), GetLastError()));
         continue;
      }

      Log(StringFormat("TRADE OK | index=%d | ticket=%I64u | symbol=%s | lot=%.3f | entry=%.5f | expiry=%s",
                       i, trade.ResultOrder(), tradeSymbol, lot, entry, expiryText));
   }
}