//+------------------------------------------------------------------+
//|                            Valetax_Cent_XAU_Scalper.mq5          |
//|         Versi Agresif / Scalping untuk target harian $10         |
//+------------------------------------------------------------------+
#property copyright "Valetax Cent XAU Scalper"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== INPUT ===
input group "=== Lot Size ==="
input double   LotSize         = 0.01;      // Lot utama
input double   LotSize2        = 0.02;      // Lot kedua
input double   BalanceForLot2  = 6000;      // Naik lot jika balance ≥ 6000 cent ($60)

input group "=== Strategi Scalping ==="
input int      FastMA          = 5;         // Fast EMA
input int      SlowMA          = 13;        // Slow EMA
input int      RSI_Period      = 7;         // RSI cepat
input int      RSI_BuyLevel    = 45;        // RSI di bawah ini boleh Buy
input int      RSI_SellLevel   = 55;        // RSI di atas ini boleh Sell

input group "=== Risk (Agresif) ==="
input int      SL_Points       = 90;        // Stop Loss (points)
input int      TP_Points       = 140;       // Take Profit (points) ≈ RR 1:1.5
input int      BE_Trigger      = 50;        // Pindah ke Break Even setelah (points)
input int      BE_Offset       = 15;        // Offset BE
input int      Trail_Start     = 70;        // Mulai trailing
input int      Trail_Step      = 25;        // Step trailing
input double   MaxSpread       = 28.0;      // Max spread (points)

input group "=== Filter ==="
input bool     UseTimeFilter   = true;
input int      StartHour       = 9;         // Mulai trading (server time)
input int      EndHour         = 20;        // Selesai
input ulong    MagicNumber     = 20260920;
input int      Slippage        = 25;

//=== GLOBAL ===
double pointValue;
int    digits;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   Print("=== XAUUSD SCALPER CENT SIAP ===");
   Print("Target harian: ±1000 USC ($10)");
   Print("SL: ", SL_Points, " | TP: ", TP_Points, " points");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(CountPositions() > 0)
   {
      ManagePositions();
      return;
   }

   // Filter waktu
   if(UseTimeFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < StartHour || dt.hour >= EndHour) return;
   }

   // Cek spread
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pointValue;
   if(spread > MaxSpread) return;

   // Indikator
   double maFast[], maSlow[], rsi[];
   ArraySetAsSeries(maFast, true);
   ArraySetAsSeries(maSlow, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MODE_EMA, PRICE_CLOSE), 0, 0, 3, maFast) < 3) return;
   if(CopyBuffer(iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MODE_EMA, PRICE_CLOSE), 0, 0, 3, maSlow) < 3) return;
   if(CopyBuffer(iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE), 0, 0, 3, rsi) < 3) return;

   // Lot
   double lot = LotSize;
   if(AccountInfoDouble(ACCOUNT_BALANCE) >= BalanceForLot2) lot = LotSize2;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   // === BUY Signal (lebih agresif) ===
   if(maFast[1] > maSlow[1] && maFast[2] <= maSlow[2] && rsi[1] < RSI_BuyLevel)
   {
      OpenBuy(lot);
   }

   // === SELL Signal ===
   if(maFast[1] < maSlow[1] && maFast[2] >= maSlow[2] && rsi[1] > RSI_SellLevel)
   {
      OpenSell(lot);
   }
}

//+------------------------------------------------------------------+
void OpenBuy(double lot)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - SL_Points * pointValue, digits);
   double tp  = NormalizeDouble(ask + TP_Points * pointValue, digits);

   if(trade.Buy(lot, _Symbol, ask, sl, tp, "XAU Scalp Buy"))
      Print("BUY | Lot:", lot, " SL:", sl, " TP:", tp);
   else
      Print("BUY gagal: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OpenSell(double lot)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(bid + SL_Points * pointValue, digits);
   double tp  = NormalizeDouble(bid - TP_Points * pointValue, digits);

   if(trade.Sell(lot, _Symbol, bid, sl, tp, "XAU Scalp Sell"))
      Print("SELL | Lot:", lot, " SL:", sl, " TP:", tp);
   else
      Print("SELL gagal: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   type      = PositionGetInteger(POSITION_TYPE);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = 0;

      if(type == POSITION_TYPE_BUY)
      {
         profitPts = (bid - openPrice) / pointValue;

         if(profitPts >= BE_Trigger)
         {
            double newSL = NormalizeDouble(openPrice + BE_Offset * pointValue, digits);
            if(newSL > currentSL)
               trade.PositionModify(ticket, newSL, currentTP);
         }

         if(profitPts >= Trail_Start)
         {
            double trailSL = NormalizeDouble(bid - Trail_Step * pointValue, digits);
            if(trailSL > currentSL)
               trade.PositionModify(ticket, trailSL, currentTP);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         profitPts = (openPrice - ask) / pointValue;

         if(profitPts >= BE_Trigger)
         {
            double newSL = NormalizeDouble(openPrice - BE_Offset * pointValue, digits);
            if(newSL < currentSL || currentSL == 0)
               trade.PositionModify(ticket, newSL, currentTP);
         }

         if(profitPts >= Trail_Start)
         {
            double trailSL = NormalizeDouble(ask + Trail_Step * pointValue, digits);
            if(trailSL < currentSL || currentSL == 0)
               trade.PositionModify(ticket, trailSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
   }
   return count;
}
//+------------------------------------------------------------------+
