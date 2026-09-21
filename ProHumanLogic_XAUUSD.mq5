//+------------------------------------------------------------------+
//|                                        ProHumanLogic_XAUUSD.mq5  |
//|                                  Copyright 2026, Expert Advisor  |
//+------------------------------------------------------------------+
#property copyright "Pro Human Logic XAUUSD Scalper"
#property version   "3.00"

#include <Trade\Trade.mqh>
CTrade trade;

#define EA_MAGIC 888999

//--- Input Parameters
input group "=== 1. Risk & Position Settings ==="
input double   InpBaseLotSize      = 0.04;     // Base Lot Entry (Gunakan kelipatan genap misal 0.04/0.06 agar partial close lancar)
input int      InpMaxLayers        = 3;        // Maksimal Penambahan Posisi Layer Saat Running Profit
input double   InpLayerMinDistPips = 3.0;      // Jarak Minimal Pips Running Profit Sebelum Tambah Entry Layer
input double   InpRiskRewardRatio  = 2.5;      // Risk to Reward Ratio Target Utama

input group "=== 2. Multi-Timeframe Mapping & Filter ==="
input ENUM_TIMEFRAMES InpTrendTF  = PERIOD_H1;  // Timeframe Mapping Tren Utama
input ENUM_TIMEFRAMES InpPullbackTF = PERIOD_M5;// Timeframe Konfirmasi Retest / Pullback
input int      InpTrendMAPeriod   = 200;       // EMA Mapping Structure Tren Besar
input int      InpPullbackMAPeriod= 20;        // EMA Dynamic Support/Resistance Retest
input int      InpADXThreshold    = 22;        // Filter Momentum Volatilitas (ADX > 22)

input group "=== 3. Partial Profit & Lock Risk ==="
input bool     InpUsePartialClose  = true;     // Aktifkan Partial Profit Amankan Sebagian?
input double   InpPartialTriggerPips = 2.5;    // Running Profit (Pips) untuk Amankan Partial
input double   InpPartialClosePercent= 50.0;   // % Lot Yang Ditutup (misal 50%)
input double   InpBEBufferPips     = 1.0;      // Kunci Profit SL+ (Pips di Atas Open Price)

input group "=== 4. Dynamic Trailing SL+ & Emergency Cut ==="
input bool     InpUseTrailing      = true;     // Aktifkan Trailing SL+ Mengikuti Harga?
input double   InpTrailingDistance = 2.0;      // Jarak Trailing SL+ Menguntit di Belakang Harga (Pips)
input double   InpCloseNearTPBuffer= 1.0;      // Emergency Cut jika Sisa ke TP Tinggal (Pips)

//--- Handles & Variables
int      trendMaHandle;
int      pullbackMaHandle;
int      adxHandle;
int      atrHandle;
datetime lastM5BarTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(EA_MAGIC);

   trendMaHandle    = iMA(_Symbol, InpTrendTF, InpTrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   pullbackMaHandle = iMA(_Symbol, InpPullbackTF, InpPullbackMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   adxHandle        = iADX(_Symbol, InpPullbackTF, 14);
   atrHandle        = iATR(_Symbol, InpPullbackTF, 14);

   if(trendMaHandle == INVALID_HANDLE || pullbackMaHandle == INVALID_HANDLE || 
      adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
     {
      Print("Error: Gagal menginisialisasi indikator.");
      return(INIT_FAILED);
     }

   lastM5BarTime = 0;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(trendMaHandle);
   IndicatorRelease(pullbackMaHandle);
   IndicatorRelease(adxHandle);
   IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Eksekusi Pengelolaan Posisi Aktif Pada Setiap Tick (Trailing SL+, Partial TP, Cut Near TP)
   ManageActivePositions();

   // 2. Cek Pembentukan Candle Baru di Timeframe Entry (M5)
   datetime currentBarTime = iTime(_Symbol, InpPullbackTF, 0);
   if(currentBarTime == lastM5BarTime) return;

   // 3. Ambil Data Buffer Indikator
   double trendMa[1], pullbackMa[2], adx[1], atr[1];
   ArraySetAsSeries(pullbackMa, true);

   if(CopyBuffer(trendMaHandle, 0, 0, 1, trendMa) <= 0 ||
      CopyBuffer(pullbackMaHandle, 0, 0, 2, pullbackMa) < 2 ||
      CopyBuffer(adxHandle, MAIN_LINE, 0, 1, adx) <= 0 ||
      CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0)
     {
      return;
     }

   // Filter Volatilitas Pasar (Cegah Entry Saat Sideways Parah)
   if(adx[0] < InpADXThreshold) return;

   // 4. MAPPING STRUCTURE (Arah Tren Besar H1)
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool isH1BullishTrend = (ask > trendMa[0]);
   bool isH1BearishTrend = (bid < trendMa[0]);

   // 5. BACA HARGA CANDLE (Memeriksa Retest / Pullback & Rejection)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpPullbackTF, 1, 2, rates) < 2) return;

   // Konfirmasi Rejection / Bounce dari EMA Support/Resistance
   bool isBuyPullback  = (rates[1].low <= pullbackMa[1] && rates[1].close > pullbackMa[1] && rates[1].close > rates[1].open);
   bool isSellPullback = (rates[1].high >= pullbackMa[1] && rates[1].close < pullbackMa[1] && rates[1].close < rates[1].open);

   double pipsToPoint = 10.0 * _Point;
   double slDistance  = atr[0] * 1.2;
   double tpDistance  = slDistance * InpRiskRewardRatio;

   int currentTotalPositions = GetTotalOpenPositions();

   // --- A. ENTRY UTAMA / FIRST ENTRY ---
   if(currentTotalPositions == 0)
     {
      // BUY ENTRY LOGIC
      if(isH1BullishTrend && isBuyPullback)
        {
         double sl = ask - slDistance;
         double tp = ask + tpDistance;
         if(trade.Buy(InpBaseLotSize, _Symbol, ask, sl, tp, "Pro Scalp Buy"))
            lastM5BarTime = currentBarTime;
        }
      // SELL ENTRY LOGIC
      else if(isH1BearishTrend && isSellPullback)
        {
         double sl = bid + slDistance;
         double tp = bid - tpDistance;
         if(trade.Sell(InpBaseLotSize, _Symbol, bid, sl, tp, "Pro Scalp Sell"))
            lastM5BarTime = currentBarTime;
        }
     }

   // --- B. ADD-ON ENTRY LAYER (Pyramiding saat Floating Profit Menguat) ---
   else if(currentTotalPositions > 0 && currentTotalPositions < InpMaxLayers)
     {
      ENUM_POSITION_TYPE activeType = GetActivePositionType();
      double lastOpenPrice = GetLastPositionOpenPrice();

      // Penambahan Posisi Buy jika Entry Pertama Running Profit & Sesuai Mapping
      if(activeType == POSITION_TYPE_BUY && isH1BullishTrend && isBuyPullback)
        {
         if(bid - lastOpenPrice >= (InpLayerMinDistPips * pipsToPoint))
           {
            double sl = ask - slDistance;
            double tp = ask + tpDistance;
            if(trade.Buy(InpBaseLotSize, _Symbol, ask, sl, tp, "Layer Buy"))
               lastM5BarTime = currentBarTime;
           }
        }
      // Penambahan Posisi Sell jika Entry Pertama Running Profit & Sesuai Mapping
      else if(activeType == POSITION_TYPE_SELL && isH1BearishTrend && isSellPullback)
        {
         if(lastOpenPrice - ask >= (InpLayerMinDistPips * pipsToPoint))
           {
            double sl = bid + slDistance;
            double tp = bid - tpDistance;
            if(trade.Sell(InpBaseLotSize, _Symbol, bid, sl, tp, "Layer Sell"))
               lastM5BarTime = currentBarTime;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Fungsi Pengelolaan Trailing SL+, Partial TP & Cut Near TP        |
//+------------------------------------------------------------------+
void ManageActivePositions()
  {
   double pipsToPoint   = 10.0 * _Point;
   double beBuffer      = InpBEBufferPips * pipsToPoint;
   double trailingDist  = InpTrailingDistance * pipsToPoint;
   double nearTPBuffer  = InpCloseNearTPBuffer * pipsToPoint;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
        {
         ulong  ticket       = PositionGetInteger(POSITION_TICKET);
         double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL    = PositionGetDouble(POSITION_SL);
         double currentTP    = PositionGetDouble(POSITION_TP);
         double currentVolume= PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         // --- LOGIKA KELOLA POSISI BUY ---
         if(type == POSITION_TYPE_BUY)
           {
            double profitPips = (bid - openPrice) / pipsToPoint;

            // 1. Emergency Cut jika Jarak ke TP Tinggal Sedikit Lalu Melambat
            if(currentTP > 0 && (currentTP - bid) <= nearTPBuffer)
              {
               trade.PositionClose(ticket);
               Print("Emergency Cut: Posisi Buy diamankan mendekati TP");
               continue;
              }

            // 2. Partial Profit (Kunci Sebagian Keuntungan)
            if(InpUsePartialClose && profitPips >= InpPartialTriggerPips && currentVolume >= (InpBaseLotSize * 0.99))
              {
               double closeVol = NormalizeDouble(currentVolume * (InpPartialClosePercent / 100.0), 2);
               if(closeVol > 0)
                 {
                  trade.PositionClosePartial(ticket, closeVol);
                  // Pasang SL+ di atas Open Price setelah partial close
                  double initialSLPlus = openPrice + beBuffer;
                  trade.PositionModify(ticket, initialSLPlus, currentTP);
                  Print("Partial Close 50% & Lock SL+ Berhasil pada Buy");
                  continue;
                 }
              }

            // 3. Dynamic Step Trailing SL+ (Menguntit di Belakang Harga Running)
            if(InpUseTrailing && profitPips >= InpTrailingDistance)
              {
               double proposedSL = bid - trailingDist;
               if(proposedSL > currentSL + (2 * _Point) && proposedSL > openPrice)
                 {
                  trade.PositionModify(ticket, proposedSL, currentTP);
                 }
              }
           }

         // --- LOGIKA KELOLA POSISI SELL ---
         else if(type == POSITION_TYPE_SELL)
           {
            double profitPips = (openPrice - ask) / pipsToPoint;

            // 1. Emergency Cut jika Jarak ke TP Tinggal Sedikit Lalu Melambat
            if(currentTP > 0 && (ask - currentTP) <= nearTPBuffer)
              {
               trade.PositionClose(ticket);
               Print("Emergency Cut: Posisi Sell diamankan mendekati TP");
               continue;
              }

            // 2. Partial Profit (Kunci Sebagian Keuntungan)
            if(InpUsePartialClose && profitPips >= InpPartialTriggerPips && currentVolume >= (InpBaseLotSize * 0.99))
              {
               double closeVol = NormalizeDouble(currentVolume * (InpPartialClosePercent / 100.0), 2);
               if(closeVol > 0)
                 {
                  trade.PositionClosePartial(ticket, closeVol);
                  // Pasang SL+ di bawah Open Price setelah partial close
                  double initialSLPlus = openPrice - beBuffer;
                  trade.PositionModify(ticket, initialSLPlus, currentTP);
                  Print("Partial Close 50% & Lock SL+ Berhasil pada Sell");
                  continue;
                 }
              }

            // 3. Dynamic Step Trailing SL+ (Menguntit di Belakang Harga Running)
            if(InpUseTrailing && profitPips >= InpTrailingDistance)
              {
               double proposedSL = ask + trailingDist;
               if((currentSL == 0 || proposedSL < currentSL - (2 * _Point)) && proposedSL < openPrice)
                 {
                  trade.PositionModify(ticket, proposedSL, currentTP);
                 }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
int GetTotalOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         count++;
     }
   return count;
  }

ENUM_POSITION_TYPE GetActivePositionType()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
     }
   return POSITION_TYPE_BUY;
  }

double GetLastPositionOpenPrice()
  {
   double lastPrice = 0;
   datetime latestTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
        {
         datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(posTime > latestTime)
           {
            latestTime = posTime;
            lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
           }
        }
     }
   return lastPrice;
  }
//+------------------------------------------------------------------+
