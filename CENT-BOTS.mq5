//+------------------------------------------------------------------+
//|                                                ScalperCentM5.mq5 |
//|                                  Copyright 2026, Expert Advisor  |
//+------------------------------------------------------------------+
#property copyright "EA Scalper Cent M5"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== Pengaturan Lot & Posisi ==="
input double   InpLotSize        = 0.10;     // Ukuran Lot per Entry
input int      InpMaxOrders      = 4;        // Jumlah Posisi Sekali Eksekusi

input group "=== Parameter Target (Pips) ==="
input double   InpTakeProfitPips = 3.0;      // Take Profit (Pips)
input double   InpStopLossPips   = 3.0;      // Initial Stop Loss (Pips)
input double   InpMaxSpreadPips  = 1.0;      // Maksimal Spread Toleransi (Pips)

input group "=== Fitur SL+ & Trailing Stop (Pips) ==="
input bool     InpUseTrailing    = true;     // Aktifkan SL+ / Trailing Stop?
input double   InpTrailingStart  = 1.0;      // Jarak Running Profit untuk Aktifkan SL+ (Pips)
input double   InpTrailingStep   = 0.5;      // Jarak Kunci Profit / Geser SL (Pips)

input group "=== Filter Trend (M5) ==="
input int      InpMAPeriod       = 20;       // Periode Moving Average

//--- Global Variables
int      maHandle;
datetime lastBarTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(777123);
   
   maHandle = iMA(_Symbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
     {
      Print("Gagal menginisialisasi Indikator MA");
      return(INIT_FAILED);
     }
     
   lastBarTime = 0;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(maHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Eksekusi Trailing Stop / SL+ pada setiap pergerakan harga (Tick)
   if(InpUseTrailing)
     {
      ApplyTrailingStop();
     }

   // 2. Hanya eksekusi entry baru pada penutupan/pembukaan candle M5 baru
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;

   // Cek apakah masih ada posisi aktif
   if(PositionsTotal() > 0)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 777123)
            return; 
        }
     }

   // Filter Spread
   double currentSpread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double maxSpreadAllowed = InpMaxSpreadPips * 10 * _Point;
   if(currentSpread > maxSpreadAllowed) return;

   // Ambil Data MA
   double maVal[];
   ArraySetAsSeries(maVal, true);
   if(CopyBuffer(maHandle, 0, 0, 2, maVal) < 2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double pipsToPoint = 10.0 * _Point; 
   double tpDistance = InpTakeProfitPips * pipsToPoint;
   double slDistance = InpStopLossPips * pipsToPoint;

   bool isBuyTrend  = (ask > maVal[0]);
   bool isSellTrend = (bid < maVal[0]);

   // Eksekusi Entry
   if(isBuyTrend)
     {
      double sl = ask - slDistance;
      double tp = ask + tpDistance;
      for(int i = 0; i < InpMaxOrders; i++)
        {
         trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Scalp Buy Cent");
        }
      lastBarTime = currentBarTime;
     }
   else if(isSellTrend)
     {
      double sl = bid + slDistance;
      double tp = bid - tpDistance;
      for(int i = 0; i < InpMaxOrders; i++)
        {
         trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Scalp Sell Cent");
        }
      lastBarTime = currentBarTime;
     }
  }

//+------------------------------------------------------------------+
//| Fungsi Menggeser SL+ / Trailing Stop                             |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
  {
   double pipsToPoint = 10.0 * _Point;
   double startDist   = InpTrailingStart * pipsToPoint;
   double stepDist    = InpTrailingStep * pipsToPoint;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 777123)
        {
         ulong  ticket      = PositionGetInteger(POSITION_TICKET);
         double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL   = PositionGetDouble(POSITION_SL);
         double currentTP   = PositionGetDouble(POSITION_TP);
         long   type        = PositionGetInteger(POSITION_TYPE);

         if(type == POSITION_TYPE_BUY)
           {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            // Cek jika harga running sudah naik sejauh TrailingStart
            if(bid - openPrice >= startDist)
              {
               double newSL = bid - stepDist;
               // Geser SL hanya jika SL baru lebih tinggi dari SL lama & sudah di atas openPrice (SL+)
               if(newSL > currentSL && newSL > openPrice)
                 {
                  trade.PositionModify(ticket, newSL, currentTP);
                 }
              }
           }
         else if(type == POSITION_TYPE_SELL)
           {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            // Cek jika harga running sudah turun sejauh TrailingStart
            if(openPrice - ask >= startDist)
              {
               double newSL = ask + stepDist;
               // Geser SL hanya jika SL baru lebih rendah dari SL lama & sudah di bawah openPrice (SL+)
               if((currentSL == 0 || newSL < currentSL) && newSL < openPrice)
                 {
                  trade.PositionModify(ticket, newSL, currentTP);
                 }
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
