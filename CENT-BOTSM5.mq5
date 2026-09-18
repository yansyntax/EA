//+------------------------------------------------------------------+
//|                                           FastScalperCentM5.mq5  |
//|                                  Copyright 2026, Expert Advisor  |
//+------------------------------------------------------------------+
#property copyright "EA Fast Scalper Cent M5"
#property version   "2.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== Target Harian (Cent) ==="
input bool     InpUseDailyTarget = true;     // Aktifkan Batas Target Harian?
input double   InpDailyTarget    = 2000.0;   // Target Profit Harian (dalam Cent)

input group "=== Pengaturan Lot & Posisi ==="
input double   InpLotSize        = 0.10;     // Ukuran Lot per Entry
input int      InpMaxOrders      = 4;        // Jumlah Posisi Sekali Eksekusi
input bool     InpAutoCutOpposite= true;     // Auto Cut/Tutup Posisi jika Sinyal Berbalik Arah?

input group "=== Parameter Target (Pips) ==="
input double   InpTakeProfitPips = 3.0;      // Take Profit (Pips)
input double   InpStopLossPips   = 3.0;      // Initial Stop Loss (Pips)
input double   InpMaxSpreadPips  = 1.0;      // Maksimal Spread Toleransi (Pips)

input group "=== Fitur SL+ & Trailing Stop (Pips) ==="
input bool     InpUseTrailing    = true;     // Aktifkan SL+ / Trailing Stop?
input double   InpTrailingStart  = 1.0;      // Jarak Running Profit untuk Aktifkan SL+ (Pips)
input double   InpTrailingStep   = 0.5;      // Jarak Kunci Profit / Geser SL (Pips)

input group "=== Indikator Sinyal Cepat (EMA & RSI) ==="
input int      InpFastEMAPeriod  = 8;        // Periode Fast EMA
input int      InpSlowEMAPeriod  = 21;       // Periode Slow EMA
input int      InpRSIPeriod      = 14;       // Periode RSI

//--- Global Variables
int      fastEmaHandle;
int      slowEmaHandle;
int      rsiHandle;
datetime lastBarTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(777123);
   
   fastEmaHandle = iMA(_Symbol, _Period, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowEmaHandle = iMA(_Symbol, _Period, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);

   if(fastEmaHandle == INVALID_HANDLE || slowEmaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
     {
      Print("Gagal menginisialisasi Indikator Sinyal Cepat");
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
   IndicatorRelease(fastEmaHandle);
   IndicatorRelease(slowEmaHandle);
   IndicatorRelease(rsiHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Eksekusi Trailing Stop / SL+
   if(InpUseTrailing)
     {
      ApplyTrailingStop();
     }

   // 2. Cek Target Harian (2000 Cent)
   if(InpUseDailyTarget && GetTodayProfit() >= InpDailyTarget)
     {
      Comment("Target Profit Harian Tercapai: ", GetTodayProfit(), " Cent. EA Istirahat.");
      return; 
     }

   // 3. Evaluasi Sinyal pada Candle Baru M5
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;

   // Filter Spread
   double currentSpread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double maxSpreadAllowed = InpMaxSpreadPips * 10 * _Point;
   if(currentSpread > maxSpreadAllowed) return;

   // Ambil data buffer indikator
   double fastEma[2], slowEma[2], rsi[1];
   ArraySetAsSeries(fastEma, true);
   ArraySetAsSeries(slowEma, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(fastEmaHandle, 0, 1, 2, fastEma) < 2) return;
   if(CopyBuffer(slowEmaHandle, 0, 1, 2, slowEma) < 2) return;
   if(CopyBuffer(rsiHandle, 0, 1, 1, rsi) < 1) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double pipsToPoint = 10.0 * _Point; 
   double tpDistance = InpTakeProfitPips * pipsToPoint;
   double slDistance = InpStopLossPips * pipsToPoint;

   // Logika Sinyal
   bool isBuySignal  = (fastEma[1] > slowEma[1] && fastEma[2] <= slowEma[2]) && (rsi[0] > 50.0);
   bool isSellSignal = (fastEma[1] < slowEma[1] && fastEma[2] >= slowEma[2]) && (rsi[0] < 50.0);

   // Jika ada sinyal BUY baru
   if(isBuySignal)
     {
      // Auto-Cut posisi SELL yang masih aktif jika sinyal berubah jadi BUY
      if(InpAutoCutOpposite) ClosePositionsByType(POSITION_TYPE_SELL);

      if(!HasOpenPositions())
        {
         double sl = ask - slDistance;
         double tp = ask + tpDistance;
         for(int i = 0; i < InpMaxOrders; i++)
           {
            trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Fast Scalp Buy Cent");
           }
         lastBarTime = currentBarTime;
        }
     }
   // Jika ada sinyal SELL baru
   else if(isSellSignal)
     {
      // Auto-Cut posisi BUY yang masih aktif jika sinyal berubah jadi SELL
      if(InpAutoCutOpposite) ClosePositionsByType(POSITION_TYPE_BUY);

      if(!HasOpenPositions())
        {
         double sl = bid + slDistance;
         double tp = bid - tpDistance;
         for(int i = 0; i < InpMaxOrders; i++)
           {
            trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Fast Scalp Sell Cent");
           }
         lastBarTime = currentBarTime;
        }
     }
  }

//+------------------------------------------------------------------+
//| Cek Posisi Aktif dengan Magic Number                             |
//+------------------------------------------------------------------+
bool HasOpenPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 777123)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Fungsi Auto-Cut Posisi Berdasarkan Tipe (BUY/SELL)              |
//+------------------------------------------------------------------+
void ClosePositionsByType(enum_position_type posType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 777123)
        {
         if(PositionGetInteger(POSITION_TYPE) == posType)
           {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            trade.PositionClose(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Hitung Profit Hari Ini (Cent)                                    |
//+------------------------------------------------------------------+
double GetTodayProfit()
  {
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(todayStart, TimeCurrent());
   
   double totalProfit = 0;
   int deals = HistoryDealsTotal();
   
   for(int i = 0; i < deals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == 777123)
        {
         totalProfit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
        }
     }
   return totalProfit;
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
            if(bid - openPrice >= startDist)
              {
               double newSL = bid - stepDist;
               if(newSL > currentSL && newSL > openPrice)
                 {
                  trade.PositionModify(ticket, newSL, currentTP);
                 }
              }
           }
         else if(type == POSITION_TYPE_SELL)
           {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(openPrice - ask >= startDist)
              {
               double newSL = ask + stepDist;
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
