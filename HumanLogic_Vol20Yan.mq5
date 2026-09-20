//+------------------------------------------------------------------+
//|                                              HumanLogic_Vol20.mq5|
//|                                Copyright 2026, Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "Expert Advisor Vol20"
#property version   "1.00"
#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters
input group "=== Risk Management ==="
input double   InpRiskPercent   = 1.0;       // Risiko per trade (%)
input double   InpRRRatio       = 2.0;       // Risk to Reward Ratio (1:X)

input group "=== Indicator Settings ==="
input int      InpADXPeriod     = 14;        // ADX Period (Sideways Filter)
input int      InpADXThreshold  = 20;        // Minimal ADX untuk Trend (Di bawah ini = Sideways)
input int      InpATRPeriod     = 14;        // ATR Period (SL & Trailing)

//--- Handles
int adxHandle;
int atrHandle;
int maH1Handle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Handle ADX di M5 (Filter Sideways)
   adxHandle = iADX(_Symbol, PERIOD_M5, InpADXPeriod);
   // Handle ATR di M5 (Untuk Dynamic SL)
   atrHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   // Handle Moving Average di H1 (Trend Bias Utama)
   maH1Handle = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE || maH1Handle == INVALID_HANDLE)
     {
      Print("Gagal membuat handle indikator.");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(adxHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(maH1Handle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Cek Posisi Terbuka (Jalan Manajemen SL+)
   ManageBreakEven();

   // Pastikan hanya 1 posisi aktif dalam satu waktu
   if(PositionsTotal() > 0) return;

   // 2. Baca Data Indikator
   double adxValues[];
   double atrValues[];
   double maH1Values[];
   
   ArraySetAsSeries(adxValues, true);
   ArraySetAsSeries(atrValues, true);
   ArraySetAsSeries(maH1Values, true);

   if(CopyBuffer(adxHandle, MAIN_LINE, 0, 1, adxValues) <= 0 ||
      CopyBuffer(atrHandle, 0, 0, 1, atrValues) <= 0 ||
      CopyBuffer(maH1Handle, 0, 0, 2, maH1Values) <= 0)
     {
      return;
     }

   // 3. Filter Sideways (Jika ADX di bawah threshold, BOT DIAM/NO TRADE)
   if(adxValues[0] < InpADXThreshold)
     {
      // Market Sideways, bot tidak melakukan analisis entry
      return;
     }

   // 4. Analisis Tren H1 (Big Picture)
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isH1Bullish = (currentPrice > maH1Values[0]);
   bool isH1Bearish = (currentPrice < maH1Values[0]);

   // 5. Cek Candlestick Confirmation di M5
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 2, rates) < 2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   double slDistance = atrValues[0] * 1.5; // SL berdasarkan 1.5x ATR
   double lotSize = CalculateLotSize(slDistance);

   // Logika Buy: Tren H1 Bullish + Candle M5 Bullish Engulfing/Pinbar
   if(isH1Bullish && rates[0].close > rates[0].open && rates[1].close < rates[1].open)
     {
      double sl = bid - slDistance;
      double tp = bid + (slDistance * InpRRRatio);
      trade.Buy(lotSize, _Symbol, ask, sl, tp, "HumanLogic Buy");
     }
   
   // Logika Sell: Tren H1 Bearish + Candle M5 Bearish Engulfing/Pinbar
   else if(isH1Bearish && rates[0].close < rates[0].open && rates[1].close > rates[1].open)
     {
      double sl = ask + slDistance;
      double tp = ask - (slDistance * InpRRRatio);
      trade.Sell(lotSize, _Symbol, bid, sl, tp, "HumanLogic Sell");
     }
  }

//+------------------------------------------------------------------+
//| Fungsi Menghitung Lot Berdasarkan Risiko %                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistanceInPrice)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(slDistanceInPrice == 0 || tickSize == 0) return 0.01;

   double pointsAtRisk = slDistanceInPrice / tickSize;
   double lot = riskAmount / (pointsAtRisk * tickValue);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   return MathMin(maxLot, MathMax(minLot, NormalizeDouble(lot, 2)));
  }

//+------------------------------------------------------------------+
//| Fungsi Menggeser SL ke Breakeven (SL+)                           |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL  = PositionGetDouble(POSITION_SL);
         double currentTP  = PositionGetDouble(POSITION_TP);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double riskDistance = MathAbs(openPrice - currentSL);

         // Jika running profit sudah mencapai 1x Risk, pindahkan SL ke Open Price + Spread (SL+)
         if(type == POSITION_TYPE_BUY)
           {
            if((currentPrice - openPrice) >= riskDistance && currentSL < openPrice)
              {
               trade.PositionModify(ticket, openPrice + (10 * _Point), currentTP);
               Print("SL Pindah ke Breakeven (SL+) untuk Buy");
              }
           }
         else if(type == POSITION_TYPE_SELL)
           {
            if((openPrice - currentPrice) >= riskDistance && (currentSL > openPrice || currentSL == 0))
              {
               trade.PositionModify(ticket, openPrice - (10 * _Point), currentTP);
               Print("SL Pindah ke Breakeven (SL+) untuk Sell");
              }
           }
        }
     }
  }
