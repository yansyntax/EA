//+------------------------------------------------------------------+
//|                                                   SCALPER_M1.mq5 |
//|  XAUUSD M1/M5 pullback/trend scalper for MT5 hedging accounts.   |
//|                                                                  |
//|  Important: this EA does not promise a win rate. Test it on a    |
//|  demo account and validate the inputs against the broker's symbol |
//|  contract, spread, commission and execution conditions.          |
//+------------------------------------------------------------------+
#property copyright "AUTOWIN90%"
#property version   "2.10"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

input group "Identity and execution"
input string InpTradeSymbol = "";                 // Empty = chart symbol
input long   InpMagicNumber = 90909001;
input bool   InpRequireGoldSymbol = true;         // Symbol name must contain XAUUSD
input int    InpMaxSpreadPoints = 50;             // Maximum spread in symbol points
input int    InpCooldownBars = 2;                 // Bars to wait after a basket closes
input int    InpDeviationPoints = 30;
input bool   InpAllowBuy = true;
input bool   InpAllowSell = true;

input group "Five layer volumes"
input double InpLayer1Lots = 0.01;
input double InpLayer2Lots = 0.01;
input double InpLayer3Lots = 0.01;
input double InpLayer4Lots = 0.01;
input double InpLayer5Lots = 0.01;
input double InpMaxTotalLots = 0.05;              // Low-risk total volume guard

input group "Basket profit and loss (account currency units, USC on a cent account)"
input double InpBasketProfitTargetUSC = 0.10;     // Close all five at/above this total profit
input double InpBasketCutUSC = 10.00;             // Close all five at/below this total loss

input group "Daily guard (account currency units, USC on a cent account)"
input double InpDailyProfitLimitUSC = 1500.00;
input double InpDailyLossLimitUSC = 50.00;
input bool   InpCloseAtDailyLimit = true;

input group "M1 trend and pullback signal"
input int    InpFastEMAPeriod = 9;
input int    InpSlowEMAPeriod = 21;
input int    InpTrendEMAPeriod = 50;
input int    InpRSIPeriod = 14;
input double InpBuyRSIMax = 58.0;                 // Pullback must not be overbought
input double InpSellRSIMin = 42.0;                // Pullback must not be oversold
input double InpMinStrongBodyPercent = 55.0;     // Body/range of confirmation candle
input int    InpMinStrongBodyPoints = 10;
input int    InpPullbackTolerancePoints = 30;     // Distance from fast EMA
input bool   InpRequireBreakOfPullback = true;
input bool   InpUseADXFilter = true;
input int    InpADXPeriod = 14;
input double InpMinADX = 18.0;

input group "M5 area confirmation"
input bool   InpRequireM5Context = true;
input int    InpM5FastEMAPeriod = 9;
input int    InpM5SlowEMAPeriod = 21;
input int    InpM5LookbackBars = 24;
input int    InpM5ZoneTolerancePoints = 80;
input bool   InpUseM5FVG = true;
input bool   InpUseM5LiquiditySweep = true;
input bool   InpUseM5MSS = true;

int fastEmaHandle = INVALID_HANDLE;
int slowEmaHandle = INVALID_HANDLE;
int trendEmaHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
int adxHandle = INVALID_HANDLE;
int m5FastEmaHandle = INVALID_HANDLE;
int m5SlowEmaHandle = INVALID_HANDLE;
datetime lastBarTime = 0;
datetime lastBasketCloseTime = 0;
string tradeSymbol = "";

double LayerLots(const int layer)
{
   switch(layer)
   {
      case 1: return InpLayer1Lots;
      case 2: return InpLayer2Lots;
      case 3: return InpLayer3Lots;
      case 4: return InpLayer4Lots;
      case 5: return InpLayer5Lots;
   }
   return 0.0;
}

string LayerComment(const int layer)
{
   return "AUTOWIN90% L" + IntegerToString(layer);
}

bool IsHedgingAccount()
{
   const ENUM_ACCOUNT_MARGIN_MODE mode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
}

bool IsGoldSymbol(const string symbol)
{
   string upper = symbol;
   StringToUpper(upper);
   return StringFind(upper, "XAUUSD") >= 0;
}

double NormalizeVolume(const double requested)
{
   const double minimum = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   const double maximum = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   if(minimum <= 0.0 || maximum <= 0.0 || step <= 0.0)
      return 0.0;

   double volume = MathMax(minimum, MathMin(maximum, requested));
   volume = MathFloor((volume + 1e-9) / step) * step;
   volume = MathMax(minimum, MathMin(maximum, volume));

   int digits = 0;
   double probe = step;
   while(digits < 8 && MathAbs(probe - MathRound(probe)) > 1e-8)
   {
      probe *= 10.0;
      digits++;
   }
   return NormalizeDouble(volume, digits);
}

bool ReadBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, buffer, shift, 1, values) != 1)
      return false;
   value = values[0];
   return value != EMPTY_VALUE;
}

bool IsNewBar()
{
   const datetime currentBar = iTime(tradeSymbol, PERIOD_M1, 0);
   if(currentBar <= 0 || currentBar == lastBarTime)
      return false;
   lastBarTime = currentBar;
   return true;
}

datetime StartOfServerDay()
{
   MqlDateTime parts;
   TimeToStruct(TimeCurrent(), parts);
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts);
}

double TodayNetResult()
{
   const datetime from = StartOfServerDay();
   const datetime to = TimeCurrent();
   if(!HistorySelect(from, to))
      return 0.0;

   double result = 0.0;
   const int total = HistoryDealsTotal();
   for(int index = 0; index < total; index++)
   {
      const ulong ticket = HistoryDealGetTicket(index);
      if(ticket == 0)
         continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != tradeSymbol)
         continue;

      result += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      result += HistoryDealGetDouble(ticket, DEAL_SWAP);
      result += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      result += HistoryDealGetDouble(ticket, DEAL_FEE);
   }
   return result;
}

bool DailyLimitReached(double &todayResult)
{
   todayResult = TodayNetResult();
   if(InpDailyProfitLimitUSC > 0.0 && todayResult >= InpDailyProfitLimitUSC)
      return true;
   if(InpDailyLossLimitUSC > 0.0 && todayResult <= -InpDailyLossLimitUSC)
      return true;
   return false;
}

int ManagedPositionCount()
{
   int count = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      const ulong ticket = PositionGetTicket(index);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != tradeSymbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      count++;
   }
   return count;
}

double ManagedBasketProfit()
{
   double result = 0.0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      const ulong ticket = PositionGetTicket(index);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != tradeSymbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      result += PositionGetDouble(POSITION_PROFIT);
      result += PositionGetDouble(POSITION_SWAP);
   }
   return result;
}

bool CloseManagedPositions(const string reason)
{
   bool allClosed = true;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      const ulong ticket = PositionGetTicket(index);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != tradeSymbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket, InpDeviationPoints))
      {
         PrintFormat("AUTOWIN90 close failed ticket=%I64u reason=%s retcode=%u %s",
                     ticket, reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
         allClosed = false;
      }
   }

   if(allClosed)
      lastBasketCloseTime = TimeCurrent();
   return allClosed;
}

void ManageOpenPositions()
{
   const int count = ManagedPositionCount();
   if(count <= 0)
      return;

   const double basketProfit = ManagedBasketProfit();
   if(InpBasketCutUSC > 0.0 && basketProfit <= -InpBasketCutUSC)
   {
      CloseManagedPositions("basket cut");
      return;
   }

   if(InpBasketProfitTargetUSC > 0.0 && basketProfit >= InpBasketProfitTargetUSC)
      CloseManagedPositions("basket profit target");
}

bool SpreadAllowed()
{
   MqlTick tick;
   if(!SymbolInfoTick(tradeSymbol, tick))
      return false;
   const double point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;
   const double spreadPoints = (tick.ask - tick.bid) / point;
   return InpMaxSpreadPoints <= 0 || spreadPoints <= InpMaxSpreadPoints;
}

bool CooldownAllowed()
{
   if(lastBasketCloseTime <= 0 || InpCooldownBars <= 0)
      return true;
   const int barsSinceClose =
      iBarShift(tradeSymbol, PERIOD_M1, lastBasketCloseTime, false);
   return barsSinceClose < 0 || barsSinceClose >= InpCooldownBars;
}

bool M5TrendMatches(const int direction, const MqlRates &rates[])
{
   double fast1, fast2, slow1, slow2;
   if(!ReadBufferValue(m5FastEmaHandle, 0, 1, fast1) ||
      !ReadBufferValue(m5FastEmaHandle, 0, 2, fast2) ||
      !ReadBufferValue(m5SlowEmaHandle, 0, 1, slow1) ||
      !ReadBufferValue(m5SlowEmaHandle, 0, 2, slow2))
      return false;

   if(direction > 0)
      return fast1 > slow1 && rates[1].close > fast1 && fast1 >= fast2 && slow1 >= slow2;
   return fast1 < slow1 && rates[1].close < fast1 && fast1 <= fast2 && slow1 <= slow2;
}

bool M5PullbackZone(const int direction, const MqlRates &rates[], const int count)
{
   const double point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   const double tolerance = InpM5ZoneTolerancePoints * point;
   double fast1;
   if(point <= 0.0 || !ReadBufferValue(m5FastEmaHandle, 0, 1, fast1))
      return false;

   for(int index = 1; index < MathMin(count, InpM5LookbackBars); index++)
   {
      if(direction > 0 &&
         rates[index].low <= fast1 + tolerance &&
         rates[index].close >= fast1 - tolerance)
         return true;
      if(direction < 0 &&
         rates[index].high >= fast1 - tolerance &&
         rates[index].close <= fast1 + tolerance)
         return true;
   }
   return false;
}

bool M5FVGZone(const int direction, const MqlRates &rates[], const int count)
{
   const double point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   const double tolerance = InpM5ZoneTolerancePoints * point;
   if(point <= 0.0)
      return false;

   const int limit = MathMin(count - 2, InpM5LookbackBars);
   for(int index = 1; index <= limit; index++)
   {
      double zoneLow = 0.0;
      double zoneHigh = 0.0;
      if(direction > 0 && rates[index].low > rates[index + 2].high)
      {
         zoneLow = rates[index + 2].high;
         zoneHigh = rates[index].low;
      }
      else if(direction < 0 && rates[index].high < rates[index + 2].low)
      {
         zoneLow = rates[index].high;
         zoneHigh = rates[index + 2].low;
      }
      else
      {
         continue;
      }

      if(rates[1].close >= zoneLow - tolerance &&
         rates[1].close <= zoneHigh + tolerance)
         return true;
   }
   return false;
}

bool M5LiquiditySweep(const int direction, const MqlRates &rates[], const int count)
{
   const int window = MathMin(6, count - 1);
   if(window < 3)
      return false;

   double previousLow = rates[2].low;
   double previousHigh = rates[2].high;
   for(int index = 2; index <= window; index++)
   {
      previousLow = MathMin(previousLow, rates[index].low);
      previousHigh = MathMax(previousHigh, rates[index].high);
   }

   if(direction > 0)
      return rates[1].low < previousLow && rates[1].close > previousLow;
   return rates[1].high > previousHigh && rates[1].close < previousHigh;
}

bool M5MarketStructureShift(const int direction, const MqlRates &rates[], const int count)
{
   const int window = MathMin(7, count - 1);
   if(window < 4)
      return false;

   double previousHigh = rates[2].high;
   double previousLow = rates[2].low;
   for(int index = 2; index <= window; index++)
   {
      previousHigh = MathMax(previousHigh, rates[index].high);
      previousLow = MathMin(previousLow, rates[index].low);
   }

   if(direction > 0)
      return rates[1].close > previousHigh;
   return rates[1].close < previousLow;
}

bool HasM5Context(const int direction)
{
   const int requestedBars = MathMax(30, MathMin(100, InpM5LookbackBars + 8));
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   const int copied = CopyRates(tradeSymbol, PERIOD_M5, 0, requestedBars, rates);
   if(copied < 12 || !M5TrendMatches(direction, rates))
      return false;

   const bool pullback = M5PullbackZone(direction, rates, copied);
   const bool fvg = InpUseM5FVG && M5FVGZone(direction, rates, copied);
   const bool sweep = InpUseM5LiquiditySweep && M5LiquiditySweep(direction, rates, copied);
   const bool mss = InpUseM5MSS && M5MarketStructureShift(direction, rates, copied);

   double fast1;
   const bool hasFast = ReadBufferValue(m5FastEmaHandle, 0, 1, fast1);
   const bool continuation =
      hasFast &&
      ((direction > 0 && rates[1].close > rates[2].high) ||
       (direction < 0 && rates[1].close < rates[2].low)) &&
      ((direction > 0 && rates[1].close > fast1) ||
       (direction < 0 && rates[1].close < fast1));

   return continuation || pullback || fvg || sweep || mss;
}

bool GetSignal(int &direction)
{
   direction = 0;
   MqlRates rates[4];
   ArraySetAsSeries(rates, true);
   if(CopyRates(tradeSymbol, PERIOD_M1, 0, 4, rates) < 4)
      return false;

   double fast1, fast2, slow1, slow2, trend1, rsi1, adx1;
   if(!ReadBufferValue(fastEmaHandle, 0, 1, fast1) ||
      !ReadBufferValue(fastEmaHandle, 0, 2, fast2) ||
      !ReadBufferValue(slowEmaHandle, 0, 1, slow1) ||
      !ReadBufferValue(slowEmaHandle, 0, 2, slow2) ||
      !ReadBufferValue(trendEmaHandle, 0, 1, trend1) ||
      !ReadBufferValue(rsiHandle, 0, 1, rsi1))
      return false;

   if(InpUseADXFilter && !ReadBufferValue(adxHandle, 0, 1, adx1))
      return false;
   if(InpUseADXFilter && adx1 < InpMinADX)
      return false;

   const double point = SymbolInfoDouble(tradeSymbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;

   const double pullbackLow = rates[2].low;
   const double pullbackHigh = rates[2].high;
   const double pullbackClose = rates[2].close;
   const double strongOpen = rates[1].open;
   const double strongClose = rates[1].close;
   const double strongHigh = rates[1].high;
   const double strongLow = rates[1].low;
   const double range = strongHigh - strongLow;
   const double body = MathAbs(strongClose - strongOpen);
   if(range <= 0.0 || body < InpMinStrongBodyPoints * point)
      return false;
   if(body / range * 100.0 < InpMinStrongBodyPercent)
      return false;

   const bool upTrend = fast1 > slow1 && slow1 > trend1 &&
                        rates[1].close > trend1 && fast1 >= fast2 && slow1 >= slow2;
   const bool downTrend = fast1 < slow1 && slow1 < trend1 &&
                          rates[1].close < trend1 && fast1 <= fast2 && slow1 <= slow2;

   const bool buyPullback =
      pullbackLow <= fast2 + InpPullbackTolerancePoints * point &&
      pullbackClose >= fast2 - InpPullbackTolerancePoints * point &&
      rsi1 <= InpBuyRSIMax;
   const bool sellPullback =
      pullbackHigh >= fast2 - InpPullbackTolerancePoints * point &&
      pullbackClose <= fast2 + InpPullbackTolerancePoints * point &&
      rsi1 >= InpSellRSIMin;

   const bool bullishConfirmation =
      strongClose > strongOpen &&
      (!InpRequireBreakOfPullback || strongClose > pullbackHigh);
   const bool bearishConfirmation =
      strongClose < strongOpen &&
      (!InpRequireBreakOfPullback || strongClose < pullbackLow);

   if(InpAllowBuy && upTrend && buyPullback && bullishConfirmation &&
      (!InpRequireM5Context || HasM5Context(1)))
   {
      direction = 1;
      return true;
   }
   if(InpAllowSell && downTrend && sellPullback && bearishConfirmation &&
      (!InpRequireM5Context || HasM5Context(-1)))
   {
      direction = -1;
      return true;
   }
   return false;
}

bool OpenFiveLayers(const int direction)
{
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(tradeSymbol);

   double totalNormalizedLots = 0.0;
   for(int layer = 1; layer <= 5; layer++)
   {
      const double normalizedLayerLots = NormalizeVolume(LayerLots(layer));
      if(normalizedLayerLots <= 0.0)
      {
         PrintFormat("AUTOWIN90 invalid volume for layer %d", layer);
         return false;
      }
      totalNormalizedLots += normalizedLayerLots;
   }
   if(InpMaxTotalLots > 0.0 && totalNormalizedLots > InpMaxTotalLots)
   {
      PrintFormat("AUTOWIN90 normalized total lots %.2f exceeds low-risk guard %.2f",
                  totalNormalizedLots, InpMaxTotalLots);
      return false;
   }

   int opened = 0;
   for(int layer = 1; layer <= 5; layer++)
   {
      const double volume = NormalizeVolume(LayerLots(layer));
      if(volume <= 0.0)
      {
         PrintFormat("AUTOWIN90 invalid volume for layer %d", layer);
         continue;
      }

      bool sent = false;
      if(direction > 0)
         sent = trade.Buy(volume, tradeSymbol, 0.0, 0.0, 0.0, LayerComment(layer));
      else
         sent = trade.Sell(volume, tradeSymbol, 0.0, 0.0, 0.0, LayerComment(layer));

      if(sent)
      {
         opened++;
         continue;
      }

      PrintFormat("AUTOWIN90 layer %d open failed retcode=%u %s",
                  layer, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      CloseManagedPositions("partial open rollback");
      return false;
   }

   if(opened != 5)
   {
      CloseManagedPositions("incomplete five-layer basket");
      return false;
   }

   PrintFormat("AUTOWIN90 opened five %s layers on %s",
               direction > 0 ? "BUY" : "SELL", tradeSymbol);
   return true;
}

int OnInit()
{
   if(_Period != PERIOD_M1)
   {
      Print("AUTOWIN90 must be attached to an M1 chart.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!IsHedgingAccount())
   {
      Print("AUTOWIN90 requires an MT5 hedging account so five independent layers can be managed.");
      return INIT_FAILED;
   }

   tradeSymbol = InpTradeSymbol == "" ? _Symbol : InpTradeSymbol;
   if(InpRequireGoldSymbol && !IsGoldSymbol(tradeSymbol))
   {
      PrintFormat("AUTOWIN90 expected an XAUUSD symbol, received %s.", tradeSymbol);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!SymbolSelect(tradeSymbol, true))
   {
      PrintFormat("AUTOWIN90 could not select symbol %s.", tradeSymbol);
      return INIT_FAILED;
   }
   if(InpBasketProfitTargetUSC <= 0.0 || InpBasketCutUSC <= 0.0 ||
      InpDailyLossLimitUSC <= 0.0 ||
      InpDailyProfitLimitUSC <= 0.0)
   {
      Print("AUTOWIN90 basket and daily limits must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   fastEmaHandle = iMA(tradeSymbol, PERIOD_M1, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowEmaHandle = iMA(tradeSymbol, PERIOD_M1, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   trendEmaHandle = iMA(tradeSymbol, PERIOD_M1, InpTrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(tradeSymbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   adxHandle = iADX(tradeSymbol, PERIOD_M1, InpADXPeriod);
   m5FastEmaHandle = iMA(tradeSymbol, PERIOD_M5, InpM5FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   m5SlowEmaHandle = iMA(tradeSymbol, PERIOD_M5, InpM5SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(fastEmaHandle == INVALID_HANDLE || slowEmaHandle == INVALID_HANDLE ||
      trendEmaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE ||
      adxHandle == INVALID_HANDLE || m5FastEmaHandle == INVALID_HANDLE ||
      m5SlowEmaHandle == INVALID_HANDLE)
   {
      Print("AUTOWIN90 failed to create indicator handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(tradeSymbol);
   PrintFormat("AUTOWIN90 ready: %s M1, account=%s, spread limit=%d points",
               tradeSymbol, AccountInfoString(ACCOUNT_CURRENCY), InpMaxSpreadPoints);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastEmaHandle != INVALID_HANDLE) IndicatorRelease(fastEmaHandle);
   if(slowEmaHandle != INVALID_HANDLE) IndicatorRelease(slowEmaHandle);
   if(trendEmaHandle != INVALID_HANDLE) IndicatorRelease(trendEmaHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(m5FastEmaHandle != INVALID_HANDLE) IndicatorRelease(m5FastEmaHandle);
   if(m5SlowEmaHandle != INVALID_HANDLE) IndicatorRelease(m5SlowEmaHandle);
}

void OnTick()
{
   if(tradeSymbol == "")
      return;

   ManageOpenPositions();

   double todayResult = 0.0;
   if(DailyLimitReached(todayResult))
   {
      if(InpCloseAtDailyLimit && ManagedPositionCount() > 0)
         CloseManagedPositions("daily limit");
      Comment("AUTOWIN90% halted for today\n",
              "Today net: ", DoubleToString(todayResult, 2), " ",
              AccountInfoString(ACCOUNT_CURRENCY));
      return;
   }

   const int managedCount = ManagedPositionCount();
   if(managedCount > 0)
   {
      Comment("AUTOWIN90% running\n",
              "Layers: ", IntegerToString(managedCount), "/5\n",
              "Basket: ", DoubleToString(ManagedBasketProfit(), 2), " ",
              AccountInfoString(ACCOUNT_CURRENCY), "\n",
              "Today: ", DoubleToString(todayResult, 2), " ",
              AccountInfoString(ACCOUNT_CURRENCY));
      return;
   }

   if(!IsNewBar() || !CooldownAllowed() || !SpreadAllowed())
      return;

   int direction = 0;
   if(GetSignal(direction))
      OpenFiveLayers(direction);
}
