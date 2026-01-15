#property strict
#property version "4.31"

#include <Trade/Trade.mqh>
CTrade trade;

input string API                = "http://127.0.0.1:3001/pull";
input int    POLL_SECONDS       = 1;
input long   MAGIC              = 2501153001;
input string COMMENT_TXT        = "";
input bool   DEBUG_LOG          = true;

// ===== NEW: Expiration for LIMIT orders (hours) =====
input int    LIMIT_EXPIRY_HOURS = 3;

long g_last_login = -1;
datetime g_last_poll = 0;

//================ LOG =================//
void Log(const string msg)
{
   if(DEBUG_LOG)
      Print(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), " | ", msg);
}

//================ UTILS =================//
bool SymbolExists(const string s)
{
   return (bool)SymbolInfoInteger(s, SYMBOL_EXIST);
}

string Trim(string s)
{
   while(StringLen(s) > 0 && (s[0]==' ' || s[0]=='\r' || s[0]=='\n' || s[0]=='\t'))
      s = StringSubstr(s, 1);

   while(StringLen(s) > 0)
   {
      int last = StringLen(s) - 1;
      ushort c = s[last];
      if(c==' ' || c=='\r' || c=='\n' || c=='\t')
         s = StringSubstr(s, 0, last);
      else
         break;
   }
   return s;
}

//================ SAFE CHART SYMBOL =================//
// chọn 1 symbol tồn tại để chart không bị MT5 kill khi đổi account
string PickSafeChartSymbol()
{
   // ưu tiên: XAUUSDc / XAUUSD / GOLD / EURUSD
   string prefer[4] = {"XAUUSDc","XAUUSD","GOLD","EURUSD"};
   for(int i=0;i<4;i++)
   {
      if(SymbolExists(prefer[i]))
         return prefer[i];
   }

   // ưu tiên MarketWatch
   int total = SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      string s = SymbolName(i,false);
      if(s != "" && SymbolExists(s))
         return s;
   }

   // fallback All symbols
   total = SymbolsTotal(true);
   for(int i=0;i<total;i++)
   {
      string s = SymbolName(i,true);
      if(s != "" && SymbolExists(s))
         return s;
   }

   return "";
}

void EnsureChartSymbolAlive()
{
   string cur = Symbol();
   if(SymbolExists(cur))
      return;

   string safe = PickSafeChartSymbol();
   if(safe == "")
   {
      Log("FATAL: no symbol exists on this account.");
      return;
   }

   bool ok = ChartSetSymbolPeriod(0, safe, (ENUM_TIMEFRAMES)Period());
   Log(StringFormat("Chart symbol invalid (%s) -> switch to %s | ok=%d", cur, safe, (int)ok));
}

//================ SYMBOL RESOLVE FOR SIGNAL =================//
string ResolveSignalSymbol(string incoming)
{
   incoming = Trim(incoming);

   // exact exists
   if(SymbolExists(incoming)) return incoming;

   // try add/remove suffix 'c'
   if(StringLen(incoming) > 0)
   {
      if(incoming[StringLen(incoming)-1] == 'c')
      {
         string cut = StringSubstr(incoming, 0, StringLen(incoming)-1);
         if(SymbolExists(cut)) return cut;
      }
      else
      {
         string addc = incoming + "c";
         if(SymbolExists(addc)) return addc;
      }
   }

   // try remove last letter (XAUUSDm -> XAUUSD)
   if(StringLen(incoming) > 1)
   {
      ushort last = incoming[StringLen(incoming)-1];
      if((last>='A'&&last<='Z') || (last>='a'&&last<='z'))
      {
         string cut = StringSubstr(incoming, 0, StringLen(incoming)-1);
         if(SymbolExists(cut)) return cut;
         string cutc = cut + "c";
         if(SymbolExists(cutc)) return cutc;
      }
   }

   // scan MarketWatch contains
   int total = SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      string s = SymbolName(i,false);
      if(s != "" && StringFind(s, incoming) >= 0 && SymbolExists(s))
         return s;
   }

   // scan All contains
   total = SymbolsTotal(true);
   for(int i=0;i<total;i++)
   {
      string s = SymbolName(i,true);
      if(s != "" && StringFind(s, incoming) >= 0 && SymbolExists(s))
         return s;
   }

   return "";
}

//================ NORMALIZE =================//
double NormalizePrice(const string sym, double price)
{
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return NormalizeDouble(price, d);
}

double NormalizeVolume(const string sym, double vol)
{
   double vmin=0, vmax=0, vstep=0;
   SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN,  vmin);
   SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX,  vmax);
   SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP, vstep);

   if(vstep <= 0) vstep = 0.01;
   if(vol < vmin) vol = vmin;
   if(vol > vmax) vol = vmax;

   double outv = MathFloor(vol / vstep) * vstep;
   if(outv < vmin) outv = vmin;
   return outv;
}

//================ HTTP =================//
bool HttpPull(const string url, string &out)
{
   ResetLastError();

   uchar data[];   ArrayResize(data,0);
   uchar result[];
   string headers = "";
   string rh = "";

   int status = WebRequest("GET", url, headers, 2000, data, result, rh);
   int err = GetLastError();

   if(DEBUG_LOG)
      Log(StringFormat("HTTP status=%d err=%d", status, err));

   if(status != 200) return false;

   out = CharArrayToString(result);
   return true;
}

//================ JSON (gốc) =================//
string GetString(string json, string key)
{
   int p = StringFind(json, "\"" + key + "\"");
   if(p < 0) return "";
   p = StringFind(json, ":", p) + 1;
   int q1 = StringFind(json, "\"", p) + 1;
   int q2 = StringFind(json, "\"", q1);
   return StringSubstr(json, q1, q2 - q1);
}

double GetDouble(string json, string key)
{
   int p = StringFind(json, "\"" + key + "\"");
   if(p < 0) return 0;
   p = StringFind(json, ":", p) + 1;
   int end = StringFind(json, ",", p);
   if(end < 0) end = StringFind(json, "}", p);
   return StringToDouble(StringSubstr(json, p, end - p));
}

int GetArrayCount(string json, string arr)
{
   int p = StringFind(json, "\"" + arr + "\"");
   if(p < 0) return 0;
   int s = StringFind(json, "[", p);
   int e = StringFind(json, "]", s);
   if(s < 0 || e < 0) return 0;
   string block = StringSubstr(json, s, e - s);
   int c = 0;
   for(int i=0;i<StringLen(block);i++)
      if(block[i] == '{') c++;
   return c;
}

double GetArrayDouble(string json, string arr, int index, string key)
{
   int p = StringFind(json, "\"" + arr + "\"");
   int s = StringFind(json, "[", p);
   if(p < 0 || s < 0) return 0;

   for(int i=0;i<=index;i++)
   {
      s = StringFind(json, "{", s + 1);
      if(s < 0) return 0;
   }

   int k = StringFind(json, "\"" + key + "\"", s);
   if(k < 0) return 0;
   k = StringFind(json, ":", k) + 1;

   int e = StringFind(json, ",", k);
   if(e < 0) e = StringFind(json, "}", k);
   if(e < 0) return 0;

   return StringToDouble(StringSubstr(json, k, e - k));
}

//================ INIT/DEINIT =================//
int OnInit()
{
   trade.SetExpertMagicNumber(MAGIC);
   g_last_login = (long)AccountInfoInteger(ACCOUNT_LOGIN);

   EnsureChartSymbolAlive();

   EventKillTimer();
   EventSetTimer(POLL_SECONDS);

   Log(StringFormat("INIT | login=%I64d | chartSymbol=%s", g_last_login, Symbol()));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Log(StringFormat("DEINIT | reason=%d", reason));
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
   if(now - g_last_poll < POLL_SECONDS) return;
   g_last_poll = now;

   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   if(login != g_last_login)
   {
      g_last_login = login;
      trade.SetExpertMagicNumber(MAGIC);

      EnsureChartSymbolAlive();

      Log(StringFormat("ACCOUNT CHANGED | login=%I64d | chartSymbol=%s", g_last_login, Symbol()));
   }

   string json = "";
   if(!HttpPull(API, json))
      return;

   json = Trim(json);
   if(StringLen(json) < 2) return;
   if(StringFind(json, "{") < 0) return;

   string symbol = GetString(json, "symbol");
   string type   = GetString(json, "type");
   double sl     = GetDouble(json, "sl");

   if(symbol == "" || type == "")
   {
      Log("PARSE FAIL");
      Log("RAW: " + json);
      return;
   }

   string tradeSymbol = ResolveSignalSymbol(symbol);
   if(tradeSymbol == "")
   {
      Log("SIGNAL SYMBOL NOT FOUND: " + symbol);
      return;
   }
   if(tradeSymbol != symbol)
      Log("SIGNAL SYMBOL RESOLVED: " + symbol + " -> " + tradeSymbol);

   SymbolSelect(tradeSymbol, true);

   int count = GetArrayCount(json, "orders");
   if(count <= 0) return;

   Log(StringFormat("SIGNAL %s %s orders=%d", tradeSymbol, type, count));

   // ===== NEW: expiration time for LIMIT orders =====
   datetime expiry = 0;
   if(LIMIT_EXPIRY_HOURS > 0)
      expiry = (datetime)(TimeCurrent() + (long)LIMIT_EXPIRY_HOURS * 3600);

   for(int i=0;i<count;i++)
   {
      double entry = GetArrayDouble(json, "orders", i, "entry");
      double tp    = GetArrayDouble(json, "orders", i, "tp");
      double lot   = GetArrayDouble(json, "orders", i, "lot");

      if(entry <= 0 || lot <= 0) continue;

      entry = NormalizePrice(tradeSymbol, entry);
      tp    = (tp > 0 ? NormalizePrice(tradeSymbol, tp) : 0.0);
      sl    = (sl > 0 ? NormalizePrice(tradeSymbol, sl) : 0.0);
      lot   = NormalizeVolume(tradeSymbol, lot);

      bool ok=false;

      // Prefer ORDER_TIME_SPECIFIED if LIMIT_EXPIRY_HOURS > 0, else GTC
      ENUM_ORDER_TYPE_TIME ttype = (LIMIT_EXPIRY_HOURS > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC);
      datetime texpires = (LIMIT_EXPIRY_HOURS > 0 ? expiry : (datetime)0);

      if(type == "BUY_LIMIT")
      {
         ok = trade.BuyLimit(lot, entry, tradeSymbol, sl, tp, ttype, texpires, COMMENT_TXT);

         // Fallback: if broker rejects SPECIFIED, try GTC
         if(!ok && ttype == ORDER_TIME_SPECIFIED)
            ok = trade.BuyLimit(lot, entry, tradeSymbol, sl, tp, ORDER_TIME_GTC, 0, COMMENT_TXT);
      }
      else if(type == "SELL_LIMIT")
      {
         ok = trade.SellLimit(lot, entry, tradeSymbol, sl, tp, ttype, texpires, COMMENT_TXT);

         // Fallback: if broker rejects SPECIFIED, try GTC
         if(!ok && ttype == ORDER_TIME_SPECIFIED)
            ok = trade.SellLimit(lot, entry, tradeSymbol, sl, tp, ORDER_TIME_GTC, 0, COMMENT_TXT);
      }

      if(!ok)
         Log(StringFormat("TRADE FAIL ret=%d %s lastErr=%d",
                          trade.ResultRetcode(),
                          trade.ResultRetcodeDescription(),
                          GetLastError()));
      else
      {
         string expTxt = (LIMIT_EXPIRY_HOURS > 0 ? TimeToString(expiry, TIME_DATE|TIME_SECONDS) : "GTC");
         Log(StringFormat("TRADE OK ticket=%I64d | expiry=%s", trade.ResultOrder(), expTxt));
      }
   }
}
