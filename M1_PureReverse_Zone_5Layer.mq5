//+------------------------------------------------------------------+
//|                               M1_PureReverse_Zone_5Layer.mq5     |
//|                               Copyright 2026, Pure Reverse Zone  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "20.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Input Parameters ---
input group "--- Settings Layering ---"
input double   InpLotSize            = 0.01;     // Lot per Entry
input int      InpLayerCount         = 5;        // Eksekusi 5 Layer
input ulong    InpMagicNumber        = 889900;   // Magic Number EA

input group "--- Target Profit & Basket Loss (Dalam USC) ---"
input double   InpTargetProfitUSC    = 0.50;     // Target Profit Gabungan (+0.50 USC Total)
input double   InpBasketMaxLossUSC   = 10.0;     // HARD BASKET CUT LOSS TOTAL (-10 USC Total)

input group "--- Zone Lookback Settings (M1) ---"
input int      InpLookbackCandles    = 30;       // Range 30 Candle M1 untuk Zone

datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   Print("EA Pure Reverse Zone (M1 5 Layer) Ready!");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

void OnTick()
  {
   // 1. KELOLA TOTAL BASKET PROFIT & BASKET CUT LOSS (-10 USC TOTAL)
   ManageBasketPL();

   // 2. Jeda 3 detik antar siklus
   if(TimeCurrent() - lastTradeTime < 3) return;

   // 3. Eksekusi Entry Pure Reverse jika Posisi Kosong
   if(CountPositions() == 0)
     {
      ExecutePureReverseEntry();
     }
  }

// --- MANAGEMENT TOTAL BASKET PROFIT & LOSS ---
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

   // Cut All Profit
   if(totalProfit >= InpTargetProfitUSC)
     {
      CloseAllPositions();
      Print("PURE REVERSE PROFIT TERCAPAI: ", totalProfit, " USC -> CUT ALL!");
      lastTradeTime = TimeCurrent();
     }
   // Hard Cut Loss (-10 USC Total Keseluruhan)
   else if(totalProfit <= -InpBasketMaxLossUSC)
     {
      CloseAllPositions();
      Print("PURE REVERSE MINUS MELEBIHI -10 USC (", totalProfit, " USC) -> FAST CUT ALL!");
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

// --- LOGIKA PURE REVERSE BERDASARKAN ZONA ---
void ExecutePureReverseEntry()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, _Period, 0, InpLookbackCandles, rates) < InpLookbackCandles) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Cari High Teratas & Low Terendah 30 Candle M1
   double highestHigh = rates[1].high;
   double lowestLow   = rates[1].low;

   for(int i = 1; i < InpLookbackCandles; i++)
     {
      if(rates[i].high > highestHigh) highestHigh = rates[i].high;
      if(rates[i].low < lowestLow)   lowestLow   = rates[i].low;
     }

   double rangeZone = highestHigh - lowestLow;
   if(rangeZone <= 0) return;

   // Level Posisi Harga (0% = Dasar Terbawah, 100% = Pucuk Tertinggi)
   double currentPriceLevel = (bid - lowestLow) / rangeZone;

   // --- DIBALIK TOTAL TANPA FILTER CANDLE ---

   // Dulu: Di Area Pucuk (>65%) disuruh SELL. Sekarang DIBALIK 100% JADI BUY 5 LAYER!
   if(currentPriceLevel >= 0.65)
     {
      Print("Harga di Area Pucuk (", currentPriceLevel * 100, "%) -> PURE REVERSE: TEMBAK 5 BUY!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "Pure Reverse Buy");
        }
      lastTradeTime = TimeCurrent();
     }
   // Dulu: Di Area Dasar (<35%) disuruh BUY. Sekarang DIBALIK 100% JADI SELL 5 LAYER!
   else if(currentPriceLevel <= 0.35)
     {
      Print("Harga di Area Dasar (", currentPriceLevel * 100, "%) -> PURE REVERSE: TEMBAK 5 SELL!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "Pure Reverse Sell");
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
