//+------------------------------------------------------------------+
//|                                  M1_Strict_Reverse_Direct.mq5    |
//|                               Copyright 2026, Pure Reverse EA    |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "23.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Input Parameters ---
input group "--- Settings Layering ---"
input double   InpLotSize            = 0.01;     // Lot per Entry
input int      InpLayerCount         = 5;        // Eksekusi Instant 5 Layer
input ulong    InpMagicNumber        = 554411;   // Magic Number EA

input group "--- Target Profit & Basket Loss (Dalam USC) ---"
input double   InpTargetProfitUSC    = 0.50;     // Target Profit Gabungan 5 Layer (0.50 USC Total)
input double   InpBasketMaxLossUSC   = 10.0;     // HARD BASKET CUT LOSS TOTAL (-10 USC Total)

datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   Print("EA Strict Reverse Direct Active!");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

void OnTick()
  {
   // 1. HARD CUT ALL JIKA TOTAL GABUNGAN MINUS -10 USC ATAU PROFIT +0.50 USC
   ManageBasketPL();

   // 2. Jeda 3 detik antar eksekusi
   if(TimeCurrent() - lastTradeTime < 3) return;

   // 3. Eksekusi Entry jika Posisi Kosong
   if(CountPositions() == 0)
     {
      ExecuteStrictReverse();
     }
  }

// --- FUNGSI KELOLA BASKET LOSS (-10 USC TOTAL) & PROFIT ---
void ManageBasketPL()
  {
   if(CountPositions() == 0) return;

   double totalProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            totalProfit += (PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
           }
        }
     }

   // Total Profit Tercapai
   if(totalProfit >= InpTargetProfitUSC)
     {
      CloseAllPositions();
      Print("BASKET PROFIT TERCAPAI: ", totalProfit, " USC -> CUT ALL!");
      lastTradeTime = TimeCurrent();
     }
   // Total Basket Loss Terpenuhi (Max -10 USC Total Keseluruhan 5 Layer)
   else if(totalProfit <= -InpBasketMaxLossUSC)
     {
      CloseAllPositions();
      Print("HARD BASKET CUT LOSS: ", totalProfit, " USC -> CLOSE ALL!");
      lastTradeTime = TimeCurrent();
     }
  }

void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            trade.PositionClose(ticket);
           }
        }
     }
  }

// --- LOGIKA MURNI DIBALIK (LILIN HIJAU -> SELL, LILIN MERAH -> BUY) ---
void ExecuteStrictReverse()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, _Period, 0, 2, rates) < 2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // HANYA CEK HARGA CLOSE & OPEN CANDLE SEBELUMNYA (INDEX 1)
   bool isBullish = rates[1].close > rates[1].open;
   bool isBearish = rates[1].close < rates[1].open;

   // LILIN HIJAU NAIK -> DIKUNCI MATI HARUS SELL 5 LAYER!
   if(isBullish)
     {
      Print("Konfirmasi Candle Hijau -> TEMBAK 5 SELL!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "Strict Reverse Sell");
        }
      lastTradeTime = TimeCurrent();
     }
   // LILIN MERAH TURUN -> DIKUNCI MATI HARUS BUY 5 LAYER!
   else if(isBearish)
     {
      Print("Konfirmasi Candle Merah -> TEMBAK 5 BUY!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "Strict Reverse Buy");
        }
      lastTradeTime = TimeCurrent();
     }
  }

int CountPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
        }
     }
   return count;
  }
