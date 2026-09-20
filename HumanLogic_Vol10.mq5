//+------------------------------------------------------------------+
//|                                              HumanLogic_Vol10.mq5|
//|                                Copyright 2026, Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "Expert Advisor Vol10"
#property version   "1.00"
#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters
input group "=== Trade Settings ==="
input double   InpRRRatio       = 2.0;       // Risk to Reward Ratio (1:X)

input group "=== Indicator Settings ==="
input int      InpADXPeriod     = 14;        // ADX Period (Sideways Filter)
input int      InpADXThreshold  = 20;        // Minimal ADX untuk Trend
input int      InpATRPeriod     = 14;        // ATR Period (SL)

input group "=== Dynamic Trailing SL+ & Protection ==="
input double   InpBEBufferPips  = 1.5;       // Jarak awal SL+ dari Open Price (Pips)
input double   InpTrailingPips  = 2.5;       // Jarak SL+ menguntit di belakang harga running (2 - 3 Pips)
input double   InpCloseNearTP   = 1.5;       // Jarak ke TP untuk Emergency Cut (Pips)

//--- Handles
int adxHandle;
int atrHandle;
int maH1Handle;

//--- Locked Parameters for Volatility 10
const double FIXED_LOT_SIZE = 0.05;          // Minimal Lot untuk VOL 10

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
   // 1. Kelola Posisi Aktif (Trailing SL+ & Emergency Cut Near TP)
   ManageActivePositions();

   // Batasi hanya 1 posisi aktif dalam satu waktu
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

   // 5. Konfirmasi Candlestick di M5
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 2, rates) < 2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double slDistance = atrValues[0] * 1.5;

   // Logika Buy
   if(isH1Bullish && rates[0].close > rates[0].open && rates[1].close < rates[1].open)
     {
      double sl = bid - slDistance;
      double tp = bid + (slDistance * InpRRRatio);
      trade.Buy(FIXED_LOT_SIZE, _Symbol, ask, sl, tp, "HumanLogic Vol10 Buy");
     }
   
   // Logika Sell
   else if(isH1Bearish && rates[0].close < rates[0].open && rates[1].close > rates[1].open)
     {
      double sl = ask + slDistance;
      double tp = ask - (slDistance * InpRRRatio);
      trade.Sell(FIXED_LOT_SIZE, _Symbol, bid, sl, tp, "HumanLogic Vol10 Sell");
     }
  }

//+------------------------------------------------------------------+
//| Fungsi Kelola Trailing SL+ Dinamis dan Cut Off Dekat TP         |
//+------------------------------------------------------------------+
void ManageActivePositions()
  {
   double point        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double beBuffer     = InpBEBufferPips * 10 * point;
   double trailingDist = InpTrailingPips * 10 * point;
   double nearTPDist   = InpCloseNearTP * 10 * point;

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

         // --- POSISI BUY ---
         if(type == POSITION_TYPE_BUY)
           {
            // A. Emergency Cut jika berjarak 1.5 pips dari TP tapi mulai berbalik
            if(currentTP > 0 && (currentTP - currentPrice) <= nearTPDist)
              {
               trade.PositionClose(ticket);
               Print("Emergency Cut: Posisi Buy ditutup mendekati TP");
               continue;
              }

            // B. Aktivasi Pertama SL+ (Breakeven + Buffer)
            if((currentPrice - openPrice) >= riskDistance && currentSL < openPrice)
              {
               double initialSLPlus = openPrice + beBuffer;
               trade.PositionModify(ticket, initialSLPlus, currentTP);
               Print("SL+ Aktif untuk Buy");
              }

            // C. Trailing SL+ (Ikut bergeser NAIK saat harga makin naik)
            if(currentSL >= openPrice)
              {
               double proposedSL = currentPrice - trailingDist;
               // Geser hanya jika SL baru lebih tinggi dari SL lama + minimal jarak perubahan
               if(proposedSL > currentSL + (2 * point))
                 {
                  trade.PositionModify(ticket, proposedSL, currentTP);
                  Print("Trailing SL+ Buy digeser naik menguntit harga");
                 }
              }
           }

         // --- POSISI SELL ---
         else if(type == POSITION_TYPE_SELL)
           {
            // A. Emergency Cut jika berjarak 1.5 pips dari TP tapi mulai berbalik
            if(currentTP > 0 && (currentPrice - currentTP) <= nearTPDist)
              {
               trade.PositionClose(ticket);
               Print("Emergency Cut: Posisi Sell ditutup mendekati TP");
               continue;
              }

            // B. Aktivasi Pertama SL+ (Breakeven - Buffer)
            if((openPrice - currentPrice) >= riskDistance && (currentSL > openPrice || currentSL == 0))
              {
               double initialSLPlus = openPrice - beBuffer;
               trade.PositionModify(ticket, initialSLPlus, currentTP);
               Print("SL+ Aktif untuk Sell");
              }

            // C. Trailing SL+ (Ikut bergeser TURUN saat harga makin turun ke bawah)
            if(currentSL <= openPrice && currentSL > 0)
              {
               double proposedSL = currentPrice + trailingDist;
               // Geser hanya jika SL baru lebih rendah dari SL lama
               if(proposedSL < currentSL - (2 * point))
                 {
                  trade.PositionModify(ticket, proposedSL, currentTP);
                  Print("Trailing SL+ Sell digeser turun menguntit harga");
                 }
              }
           }
        }
     }
  }
