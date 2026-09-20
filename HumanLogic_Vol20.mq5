//+------------------------------------------------------------------+
//|                                              HumanLogic_Vol20.mq5|
//|                                Copyright 2026, Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "Expert Advisor Vol20"
#property version   "1.10"
#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters
input group "=== Trade Settings ==="
input double   InpFixedLot      = 0.02;      // Fixed Lot Size
input double   InpRRRatio       = 2.0;       // Risk to Reward Ratio (1:X)

input group "=== Indicator Settings ==="
input int      InpADXPeriod     = 14;        // ADX Period (Sideways Filter)
input int      InpADXThreshold  = 20;        // Minimal ADX untuk Trend
input int      InpATRPeriod     = 14;        // ATR Period (SL)

input group "=== Advanced Protection & Trailing ==="
input double   InpBEBufferPips  = 2.0;       // Jarak aman SL+ diatas Open Price (dalam Pips)
input double   InpTrailingPips  = 3.0;       // Jarak Trailing Stop mengunci profit (dalam Pips)
input double   InpCloseNearTP   = 1.5;       // Jarak ke TP untuk pemicu Emergency Cut (1 - 2 Pips)

//--- Handles
int adxHandle;
int atrHandle;
int maH1Handle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   adxHandle  = iADX(_Symbol, PERIOD_M5, InpADXPeriod);
   atrHandle  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
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
   // 1. Kelola Manajemen Posisi Aktif (Trailing SL+, Close Near TP)
   ManageActivePositions();

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

   // 3. Filter Sideways
   if(adxValues[0] < InpADXThreshold) return;

   // 4. Analisis Tren H1
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isH1Bullish = (currentPrice > maH1Values[0]);
   bool isH1Bearish = (currentPrice < maH1Values[0]);

   // 5. Cek Candlestick Confirmation di M5
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 2, rates) < 2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double slDistance = atrValues[0] * 1.5;
   double lotSize    = InpFixedLot; // Menggunakan Lot 0.02 Fixed

   // Logika Buy
   if(isH1Bullish && rates[0].close > rates[0].open && rates[1].close < rates[1].open)
     {
      double sl = bid - slDistance;
      double tp = bid + (slDistance * InpRRRatio);
      trade.Buy(lotSize, _Symbol, ask, sl, tp, "HumanLogic Buy");
     }
   
   // Logika Sell
   else if(isH1Bearish && rates[0].close < rates[0].open && rates[1].close > rates[1].open)
     {
      double sl = ask + slDistance;
      double tp = ask - (slDistance * InpRRRatio);
      trade.Sell(lotSize, _Symbol, bid, sl, tp, "HumanLogic Sell");
     }
  }

//+------------------------------------------------------------------+
//| Fungsi Kelola Trailing SL+ dan Cut Off dekat TP                  |
//+------------------------------------------------------------------+
void ManageActivePositions()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double beBuffer = InpBEBufferPips * 10 * point;
   double trailingDist = InpTrailingPips * 10 * point;
   double nearTPDist = InpCloseNearTP * 10 * point;

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

         double riskDistance = MathAbs(openPrice - currentSL);

         // --- BUY POSITIONS ---
         if(type == POSITION_TYPE_BUY)
           {
            // A. Cut Manual Jika Hampir Menyentuh TP tapi Gagal/Berbalik
            if(currentTP > 0 && (currentTP - currentPrice) <= nearTPDist)
              {
               trade.PositionClose(ticket);
               Print("Emergency Cut: Posisi Buy ditutup mendekati TP (1-2 Pips)");
               continue;
              }

            // B. Set Initial SL+ (Aman dari Spread)
            if((currentPrice - openPrice) >= riskDistance && currentSL < openPrice)
              {
               double newSL = openPrice + beBuffer;
               trade.PositionModify(ticket, newSL, currentTP);
               Print("SL+ Aktif untuk Buy (Aman dari spread)");
              }

            // C. Trailing SL+ Ikut Geser Naik
            if(currentSL >= openPrice)
              {
               double newSL = currentPrice - trailingDist;
               if(newSL > currentSL + (5 * point))
                 {
                  trade.PositionModify(ticket, newSL, currentTP);
                  Print("Trailing SL+ Buy digeser naik");
                 }
              }
           }

         // --- SELL POSITIONS ---
         else if(type == POSITION_TYPE_SELL)
           {
            // A. Cut Manual Jika Hampir Menyentuh TP tapi Gagal/Berbalik
            if(currentTP > 0 && (currentPrice - currentTP) <= nearTPDist)
              {
               trade.PositionClose(ticket);
               Print("Emergency Cut: Posisi Sell ditutup mendekati TP (1-2 Pips)");
               continue;
              }

            // B. Set Initial SL+ (Aman dari Spread)
            if((openPrice - currentPrice) >= riskDistance && (currentSL > openPrice || currentSL == 0))
              {
               double newSL = openPrice - beBuffer;
               trade.PositionModify(ticket, newSL, currentTP);
               Print("SL+ Aktif untuk Sell (Aman dari spread)");
              }

            // C. Trailing SL+ Ikut Geser Turun
            if(currentSL <= openPrice && currentSL > 0)
              {
               double newSL = currentPrice + trailingDist;
               if(newSL < currentSL - (5 * point) || currentSL == 0)
                 {
                  trade.PositionModify(ticket, newSL, currentTP);
                  Print("Trailing SL+ Sell digeser turun");
                 }
              }
           }
        }
     }
  }
