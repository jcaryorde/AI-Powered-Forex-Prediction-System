//+------------------------------------------------------------------+
//|                                         VolatilityExtremeEA.mq5 |
//|                                  Copyright 2023, Algorithmic Dev |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Algorithmic Dev"
#property link      "https://www.mql5.com"
#property version   "1.02"
#property strict

/*
   STATISTICAL VOLATILITY & INSTITUTIONAL FOOTPRINT EA

   Strategy Logic:
   1. Statistical Volatility Modeling: Uses Bollinger Bands with high standard deviation (default 3.0)
      to identify price "over-extensions" that are statistically improbable (Outliers).
   2. Institutional Footprints: Monitors Tick Volume for "Climactic Spikes". A spike is defined as
      current tick volume being significantly higher (e.g., 2x) than the average of the last 20 bars.
      This indicates "Absorption" where institutional players enter to counter retail panic/greed.
   3. Trigger: When price interacts with an outer band AND a volume climax is detected,
      a Limit Order is placed at the band level to catch the mean reversion.
   4. Trade Management: Dynamic TP and SL are calculated based on the Average True Range (ATR).
   5. Strict Sequential Execution: Only one trade or pending order per asset at any time.
*/

#include <Trade\Trade.mqh>

//--- DYNAMIC USER INPUTS
input double MicroLotSize               = 0.01; // Default lot size for safe testing
input int    ATR_Period                 = 14;   // ATR Period for dynamic TP/SL
input double TakeProfit_ATR_Multiplier  = 1.0;  // ATR Multiplier for Take Profit
input double StopLoss_ATR_Multiplier    = 1.5;  // ATR Multiplier for Stop Loss
input int    BB_Period                  = 20;   // Bollinger Bands Period
input double BB_Deviation               = 3.0;  // Standard Deviation for extreme bands
input double Volume_Climax_Multiplier   = 2.0;  // Multiplier to define a volume "spike"
input ENUM_TIMEFRAMES TimeframeToUse     = PERIOD_H1; // Timeframe for analysis

//--- GLOBAL VARIABLES
CTrade trade;
string symbols[] = {"AUDUSD", "XAUUSD", "BTCUSD", "EURUSD", "GBPUSD"};
int handle_atr[];
int handle_bb[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int total = ArraySize(symbols);
   ArrayResize(handle_atr, total);
   ArrayResize(handle_bb, total);

   // Validate timeframe
   if(TimeframeToUse == PERIOD_CURRENT)
   {
      Print("Error: PERIOD_CURRENT is not allowed. Please select a specific timeframe.");
      return(INIT_FAILED);
   }

   for(int i=0; i<total; i++)
   {
      // Initialize handles for technical indicators
      handle_atr[i] = iATR(symbols[i], TimeframeToUse, ATR_Period);
      handle_bb[i]  = iBands(symbols[i], TimeframeToUse, BB_Period, 0, BB_Deviation, PRICE_CLOSE);

      if(handle_atr[i] == INVALID_HANDLE || handle_bb[i] == INVALID_HANDLE)
      {
         Print("Error initializing handles for symbol: ", symbols[i]);
         return(INIT_FAILED);
      }
   }

   trade.SetExpertMagicNumber(654321);
   Print("Volatility Extreme EA initialized. Monitoring 5 assets on timeframe: ", EnumToString(TimeframeToUse));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i=0; i<ArraySize(handle_atr); i++)
   {
      IndicatorRelease(handle_atr[i]);
      IndicatorRelease(handle_bb[i]);
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   for(int i=0; i<ArraySize(symbols); i++)
   {
      ManageSymbol(symbols[i], handle_atr[i], handle_bb[i]);
   }
}

//+------------------------------------------------------------------+
//| Core logic per symbol                                            |
//+------------------------------------------------------------------+
void ManageSymbol(string symbol, int hATR, int hBB)
{
   // 1. Strict Sequential Execution: Ensure asset is completely flat (No grid pile-ups)
   if(!IsFlat(symbol)) return;

   // 2. Statistical Volatility Modeling: Get Bollinger Bands buffers
   double upperBand[], lowerBand[];
   ArraySetAsSeries(upperBand, true);
   ArraySetAsSeries(lowerBand, true);

   // Buffer 1 is Upper Band, Buffer 2 is Lower Band for iBands
   if(CopyBuffer(hBB, 1, 0, 1, upperBand) <= 0) return;
   if(CopyBuffer(hBB, 2, 0, 1, lowerBand) <= 0) return;

   // 3. Institutional Footprints: Check for Climactic Tick Volume
   if(!IsVolumeClimax(symbol)) return;

   // 4. Dynamic Trade Management: Calculate current ATR
   double lastATR = GetATR(hATR);
   if(lastATR <= 0) return;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   // 5. Trigger Logic: Interactions with outer bands

   // BUY TRIGGER: Volume climax at the LOWER band
   if(ask <= lowerBand[0] + (5 * point)) // Allowing a small buffer for interaction
   {
      double entryPrice = NormalizeDouble(lowerBand[0], digits);

      // Ensure entry is below current ask for a Limit Order
      if(entryPrice >= ask) entryPrice = NormalizeDouble(ask - (10 * point), digits);

      double sl = NormalizeDouble(entryPrice - (lastATR * StopLoss_ATR_Multiplier), digits);
      double tp = NormalizeDouble(entryPrice + (lastATR * TakeProfit_ATR_Multiplier), digits);

      // Validate TP/SL: TP must be above entry, SL must be below entry
      if(!ValidateTradeLevels(entryPrice, tp, sl, true))
      {
         Print("Buy validation failed for ", symbol, " - Invalid TP/SL levels");
         return;
      }

      if(trade.BuyLimit(MicroLotSize, entryPrice, symbol, sl, tp))
      {
         Print("Buy Limit placed: ", symbol, " @ ", entryPrice, " SL: ", sl, " TP: ", tp);
      }
      else
      {
         Print("Buy Limit Failed [", symbol, "]: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }

   // SELL TRIGGER: Volume climax at the UPPER band
   else if(bid >= upperBand[0] - (5 * point))
   {
      double entryPrice = NormalizeDouble(upperBand[0], digits);

      // Ensure entry is above current bid for a Limit Order
      if(entryPrice <= bid) entryPrice = NormalizeDouble(bid + (10 * point), digits);

      double sl = NormalizeDouble(entryPrice + (lastATR * StopLoss_ATR_Multiplier), digits);
      double tp = NormalizeDouble(entryPrice - (lastATR * TakeProfit_ATR_Multiplier), digits);

      // Validate TP/SL: TP must be below entry, SL must be above entry
      if(!ValidateTradeLevels(entryPrice, tp, sl, false))
      {
         Print("Sell validation failed for ", symbol, " - Invalid TP/SL levels");
         return;
      }

      if(trade.SellLimit(MicroLotSize, entryPrice, symbol, sl, tp))
      {
         Print("Sell Limit placed: ", symbol, " @ ", entryPrice, " SL: ", sl, " TP: ", tp);
      }
      else
      {
         Print("Sell Limit Failed [", symbol, "]: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Validate Trade Levels (TP/SL)                                    |
//+------------------------------------------------------------------+
bool ValidateTradeLevels(double entry, double tp, double sl, bool isBuy)
{
   if(isBuy)
   {
      // For buy: TP > Entry > SL
      return (tp > entry && entry > sl && sl > 0);
   }
   else
   {
      // For sell: TP < Entry < SL
      return (tp < entry && entry < sl);
   }
}

//+------------------------------------------------------------------+
//| Check if symbol has no open positions or pending orders          |
//+------------------------------------------------------------------+
bool IsFlat(string symbol)
{
   // Check active positions
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol) return false;
      }
   }

   // Check pending orders (Limit/Stop orders)
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == symbol) return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Get last ATR value from indicator handle                         |
//+------------------------------------------------------------------+
double GetATR(int hATR)
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(hATR, 0, 0, 1, atrBuffer) > 0)
      return atrBuffer[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Tick Volume Climax                                        |
//| Statistical approach: compares current volume to 20-period SMA    |
//+------------------------------------------------------------------+
bool IsVolumeClimax(string symbol)
{
   long volume[];
   ArraySetAsSeries(volume, true);

   // Copy last 21 bars of tick volume (Index 0 is current, 1-20 are previous)
   if(CopyTickVolume(symbol, TimeframeToUse, 0, 21, volume) < 21) return false;

   double avgVolume = 0;
   for(int i=1; i<21; i++)
   {
      avgVolume += (double)volume[i];
   }
   avgVolume /= 20;

   // Current volume spike must exceed the average by the user-defined multiplier
   return ((double)volume[0] > avgVolume * Volume_Climax_Multiplier);
}
