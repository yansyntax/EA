//+------------------------------------------------------------------+
//|                                        HumanLogic_XAUUSD_v3.mq5  |
//|                          Copyright 2026, Professional EA Developer|
//+------------------------------------------------------------------+
#property copyright "Expert Advisor XAUUSD Human Brain v3"
#property version   "3.00"
#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters
input group "=== Trade & Risk Settings ==="
input double   InpFixedLot         = 0.05;      // Lot Size XAUUSD
input double   InpRRRatio          = 2.0;       // Risk to Reward Ratio (1:X)
input int      InpMaxLayers        = 2;         // Maksimal Layer (Hanya jika posisi 1 sudah SL+)

input group "=== Indicator & Mapping Settings ==="
input int      InpADXPeriod        = 14;        // ADX Period
input int      InpADXThreshold     = 20;        // Minimal ADX Normal
input int      InpADXStrict        = 30;        // Minimal ADX Pasca-Loss (Mode Belajar)
input int      InpATRPeriod        = 14;        // ATR Period untuk Dynamic SL

input group "=== Protection & Trailing Settings ==="
input double   InpBEBufferUSD      = 1.0;       // Minimal Kunci Profit SL+ Awal ($1.00 USD)

//--- Handles
int adxHandle;
int atrHandle;
int maH1FastHandle;  // EMA 50 H1
int maH1SlowHandle;  // EMA 200 H1 (Mapping Structure)
int maM5Pullback;    // EMA 20 M5 (Retest Zone)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   adxHandle      = iADX(_Symbol, PERIOD_M5, InpADXPeriod);
   atrHandle      = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   maH1FastHandle = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   maH1SlowHandle = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
   maM5Pullback   = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);

   if(adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE || 
      maH1FastHandle == INVALID_HANDLE || maH1SlowHandle == INVALID_HANDLE ||
      maM5Pullback == INVALID_HANDLE)
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
   IndicatorRelease(maH1FastHandle);
   IndicatorRelease(maH1SlowHandle);
   IndicatorRelease(maM5Pullback);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Eksekusi Multi-Stage Dynamic Trailing SL+ & Emergency Cut
   ManageMultiStageTrailing();

   // 2. Cek Batas Layer
   int totalPositions = PositionsTotal();
   if(totalPositions >= InpMaxLayers) return;

   // 3. LOGIKA BELAJAR DARI KESALAHAN (Adaptive Filter)
   bool lastWasLoss = WasLastTradeLoss();
   int activeADXThreshold = lastWasLoss ? InpADXStrict : InpADXThreshold;

   // 4. Baca Buffer Indikator
   double adxValues[];
   double atrValues[];
   double maH1Fast[];
   double maH1Slow[];
   double maM5PB[];
   
   ArraySetAsSeries(adxValues, true);
   ArraySetAsSeries(atrValues, true);
   ArraySetAsSeries(maH1Fast, true);
   ArraySetAsSeries(maH1Slow, true);
   ArraySetAsSeries(maM5PB, true);

   if(CopyBuffer(adxHandle, MAIN_LINE, 0, 1, adxValues) <= 0 ||
      CopyBuffer(atrHandle, 0, 0, 1, atrValues) <= 0 ||
      CopyBuffer(maH1FastHandle, 0, 0, 1, maH1Fast) <= 0 ||
      CopyBuffer(maH1SlowHandle, 0, 0, 1, maH1Slow) <= 0 ||
      CopyBuffer(maM5Pullback, 0, 0, 2, maM5PB) <= 0)
     {
      return;
     }

   // Filter Sideways
   if(adxValues[0] < activeADXThreshold) return;

   // 5. MARKET MAPPING (Analisis Tren Utama H1)
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Strong Bullish Mapping: Harga > EMA50 H1 DAN EMA50 H1 > EMA200 H1
   bool isBullishMapping = (bid > maH1Fast[0] && maH1Fast[0] > maH1Slow[0]);
   // Strong Bearish Mapping: Harga < EMA50 H1 DAN EMA50 H1 < EMA200 H1
   bool isBearishMapping = (ask < maH1Fast[0] && maH1Fast[0] < maH1Slow[0]);

   // 6. RETEST & PULLBACK LOGIC (M5)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 3, rates) < 3) return;

   // Retest Buy: Candle sebelumnya sempat menyentuh/menguji EMA20 M5, lalu candle running menolak turun (Bullish Reversal)
   bool isBuyPullback = (rates[1].low <= maM5PB[1] || rates[2].low <= maM5PB[2]) && 
                        (rates[0].close > rates[0].open) && 
                        (rates[1].close < rates[1].open || rates[0].close > rates[1].high);

   // Retest Sell: Candle sebelumnya sempat menyentuh/menguji EMA20 M5, lalu candle running menolak naik (Bearish Reversal)
   bool isSellPullback = (rates[1].high >= maM5PB[1] || rates[2].high >= maM5PB[2]) && 
                         (rates[0].close < rates[0].open) && 
                         (rates[1].close > rates[1].open || rates[0].close < rates[1].low);

   double slDistance = atrValues[0] * 1.5;

   // 7. SMART LAYERING SAFETY CHECK
   bool canTrade = true;
   if(totalPositions > 0)
     {
      canTrade = false; // Mesti difilter
      for(int i = 0; i < totalPositions; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
           {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            // Layer baru HANYA diizinkan jika posisi ke-1 SUDAH BEBAS RISIKO (SL+ aktif)
            if(type == POSITION_TYPE_BUY && currentSL > openPrice) canTrade = true;
            if(type == POSITION_TYPE_SELL && currentSL < openPrice && currentSL > 0) canTrade = true;
           }
        }
     }

   if(!canTrade) return;

   // --- EKSEKUSI BUY ---
   if(isBullishMapping && isBuyPullback)
     {
      double sl = bid - slDistance;
      double tp = bid + (slDistance * InpRRRatio);
      trade.Buy(InpFixedLot, _Symbol, ask, sl, tp, "HumanLogic v3 Buy");
     }
   
   // --- EKSEKUSI SELL ---
   else if(isBearishMapping && isSellPullback)
     {
      double sl = ask + slDistance;
      double tp = ask - (slDistance * InpRRRatio);
      trade.Sell(InpFixedLot, _Symbol, bid, sl, tp, "HumanLogic v3 Sell");
     }
  }

//+------------------------------------------------------------------+
//| Multi-Stage Dynamic Trailing SL+ & Emergency Cut                |
//+------------------------------------------------------------------+
void ManageMultiStageTrailing()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL    = PositionGetDouble(POSITION_SL);
         double currentTP    = PositionGetDouble(POSITION_TP);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         if(currentTP == 0) continue;

         double totalTargetDist = MathAbs(currentTP - openPrice);
         if(totalTargetDist == 0) continue;

         // --- POSISI BUY ---
         if(type == POSITION_TYPE_BUY)
           {
            double currentProfitDist = currentPrice - openPrice;
            double progressRatio     = currentProfitDist / totalTargetDist; // Persentase perjalanan ke TP (0.0 - 1.0)

            // A. TAHAP 4: Emergency Cut dekat TP (Progress >= 90% & Candle M5 Berbalik Turun)
            if(progressRatio >= 0.90)
              {
               MqlRates rates[];
               ArraySetAsSeries(rates, true);
               if(CopyRates(_Symbol, PERIOD_M5, 0, 1, rates) > 0 && rates[0].close < rates[0].open)
                 {
                  trade.PositionClose(ticket);
                  Print("Emergency Cut: Lock Profit Buy (Progres ", DoubleToString(progressRatio*100, 1), "%)");
                  continue;
                 }
              }

            // B. TAHAP 3: Trailing Ketat Menguntit Belakang Harga (Progress >= 75%)
            if(progressRatio >= 0.75)
              {
               double targetSL = openPrice + (currentProfitDist * 0.65); // Kunci 65% profit
               if(targetSL > currentSL + 0.30)
                 {
                  trade.PositionModify(ticket, targetSL, currentTP);
                  Print("Multi-Stage SL+ Buy Tahap 3 (Lock 65% Profit)");
                 }
              }
            // C. TAHAP 2: Lock 35% Profit (Progress >= 50%)
            else if(progressRatio >= 0.50)
              {
               double targetSL = openPrice + (currentProfitDist * 0.35); // Kunci 35% profit
               if(targetSL > currentSL + 0.30)
                 {
                  trade.PositionModify(ticket, targetSL, currentTP);
                  Print("Multi-Stage SL+ Buy Tahap 2 (Lock 35% Profit)");
                 }
              }
            // D. TAHAP 1: Initial SL+ Breakeven (Progress >= 30%)
            else if(progressRatio >= 0.30 && currentSL < openPrice)
              {
               double targetSL = openPrice + InpBEBufferUSD;
               trade.PositionModify(ticket, targetSL, currentTP);
               Print("Multi-Stage SL+ Buy Tahap 1 (BE Active)");
              }
           }

         // --- POSISI SELL ---
         else if(type == POSITION_TYPE_SELL)
           {
            double currentProfitDist = openPrice - currentPrice;
            double progressRatio     = currentProfitDist / totalTargetDist; // Persentase perjalanan ke TP (0.0 - 1.0)

            // A. TAHAP 4: Emergency Cut dekat TP (Progress >= 90% & Candle M5 Berbalik Naik)
            if(progressRatio >= 0.90)
              {
               MqlRates rates[];
               ArraySetAsSeries(rates, true);
               if(CopyRates(_Symbol, PERIOD_M5, 0, 1, rates) > 0 && rates[0].close > rates[0].open)
                 {
                  trade.PositionClose(ticket);
                  Print("Emergency Cut: Lock Profit Sell (Progres ", DoubleToString(progressRatio*100, 1), "%)");
                  continue;
                 }
              }

            // B. TAHAP 3: Trailing Ketat Menguntit Belakang Harga (Progress >= 75%)
            if(progressRatio >= 0.75)
              {
               double targetSL = openPrice - (currentProfitDist * 0.65); // Kunci 65% profit
               if(targetSL < currentSL - 0.30 || currentSL == 0)
                 {
                  trade.PositionModify(ticket, targetSL, currentTP);
                  Print("Multi-Stage SL+ Sell Tahap 3 (Lock 65% Profit)");
                 }
              }
            // C. TAHAP 2: Lock 35% Profit (Progress >= 50%)
            else if(progressRatio >= 0.50)
              {
               double targetSL = openPrice - (currentProfitDist * 0.35); // Kunci 35% profit
               if(targetSL < currentSL - 0.30 || currentSL == 0)
                 {
                  trade.PositionModify(ticket, targetSL, currentTP);
                  Print("Multi-Stage SL+ Sell Tahap 2 (Lock 35% Profit)");
                 }
              }
            // D. TAHAP 1: Initial SL+ Breakeven (Progress >= 30%)
            else if(progressRatio >= 0.30 && (currentSL > openPrice || currentSL == 0))
              {
               double targetSL = openPrice - InpBEBufferUSD;
               trade.PositionModify(ticket, targetSL, currentTP);
               Print("Multi-Stage SL+ Sell Tahap 1 (BE Active)");
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Cek Hasil Trade Terakhir (Self-Learning Filter)                 |
//+------------------------------------------------------------------+
bool WasLastTradeLoss()
  {
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   
   for(int i = totalDeals - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
        {
         string symbol   = HistoryDealGetString(ticket, DEAL_SYMBOL);
         long entryType  = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
         if(symbol == _Symbol && entryType == DEAL_ENTRY_OUT)
           {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            return (profit < 0);
           }
        }
     }
   return false;
  }
