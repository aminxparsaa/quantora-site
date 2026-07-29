//+------------------------------------------------------------------+
//|                                        MDX_MultiDivergence.mq5    |
//|            Multi-Oscillator Weighted Divergence Engine (MDX)      |
//|                                                                   |
//|  A low-lag, non-repainting-by-default divergence detector that    |
//|  fuses RSI, CCI, Momentum, Stochastic and MACD into a single      |
//|  weighted confidence score, with optional trend / volatility /    |
//|  session context filters.                                         |
//|                                                                   |
//|  Designed and tuned for the M1 timeframe (scalping), but works    |
//|  on any timeframe.                                                |
//|                                                                   |
//|  This is a SINGLE-FILE build: every previously separate .mqh      |
//|  module (Defs, Oscillators, Pivots, Scoring, Filters, Engine,     |
//|  Render, Alerts) has been inlined below. No custom #include is    |
//|  required to compile this file.                                   |
//+------------------------------------------------------------------+
#property copyright "MDX"
#property link      ""
#property version   "1.00"
#property description "Multi-Oscillator Weighted Divergence Engine - low-lag M1 divergence detection"
#property strict

#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   4

//--- Plot 1: Regular bullish arrow
#property indicator_label1  "Bull Div"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

//--- Plot 2: Regular bearish arrow
#property indicator_label2  "Bear Div"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  2

//--- Plot 3: Hidden bullish arrow
#property indicator_label3  "Hidden Bull"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrMediumSeaGreen
#property indicator_width3  1

//--- Plot 4: Hidden bearish arrow
#property indicator_label4  "Hidden Bear"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrMediumVioletRed
#property indicator_width4  1


//==================================================================
//  SECTION 1 : MDX_Defs  (enumerations, constants, structures)
//==================================================================
#define MDX_VERSION            "1.00"
#define MDX_MAX_OSC            5      // RSI, CCI, MOM, STOCH, MACD
#define MDX_MAX_PIVOTS         64     // ring buffer depth per side
#define MDX_MAX_SIGNAL_MEMORY  256    // duplicate-suppression memory

//+------------------------------------------------------------------+
//| Oscillator identifiers (index into arrays)                        |
//+------------------------------------------------------------------+
enum ENUM_MDX_OSC
  {
   MDX_OSC_RSI   = 0,
   MDX_OSC_CCI   = 1,
   MDX_OSC_MOM   = 2,
   MDX_OSC_STOCH = 3,
   MDX_OSC_MACD  = 4
  };

//+------------------------------------------------------------------+
//| Sensitivity presets                                               |
//+------------------------------------------------------------------+
enum ENUM_MDX_SENSITIVITY
  {
   MDX_SENS_FAST         = 0,  // earliest possible, tentative pivots allowed
   MDX_SENS_MEDIUM       = 1,  // balanced
   MDX_SENS_CONSERVATIVE = 2,  // fully confirmed pivots only
   MDX_SENS_CUSTOM       = 3   // use the manual override inputs
  };

//+------------------------------------------------------------------+
//| Divergence class                                                  |
//+------------------------------------------------------------------+
enum ENUM_MDX_DIVTYPE
  {
   MDX_DIV_NONE           = 0,
   MDX_DIV_REG_BULL       = 1,
   MDX_DIV_REG_BEAR       = 2,
   MDX_DIV_HID_BULL       = 3,
   MDX_DIV_HID_BEAR       = 4
  };

//+------------------------------------------------------------------+
//| Which divergence families to scan                                 |
//+------------------------------------------------------------------+
enum ENUM_MDX_DIVMODE
  {
   MDX_MODE_REGULAR_ONLY  = 0,
   MDX_MODE_HIDDEN_ONLY   = 1,
   MDX_MODE_BOTH          = 2
  };

//+------------------------------------------------------------------+
//| Trend filter source                                               |
//+------------------------------------------------------------------+
enum ENUM_MDX_TRENDFILTER
  {
   MDX_TREND_OFF          = 0,
   MDX_TREND_EMA          = 1,  // single EMA slope + side
   MDX_TREND_EMA_CROSS    = 2,  // fast/slow EMA relationship
   MDX_TREND_STRUCTURE    = 3   // swing-based HH/HL - LH/LL structure
  };

//+------------------------------------------------------------------+
//| How the trend filter is applied                                   |
//+------------------------------------------------------------------+
enum ENUM_MDX_TRENDMODE
  {
   MDX_TRENDMODE_BLOCK    = 0,  // veto counter-trend signals
   MDX_TRENDMODE_PENALIZE = 1   // only reduce confidence
  };

//+------------------------------------------------------------------+
//| Pivot confirmation policy                                         |
//+------------------------------------------------------------------+
enum ENUM_MDX_PIVOTPOLICY
  {
   MDX_PIVOT_CONFIRMED    = 0,  // right bars fully closed (no repaint)
   MDX_PIVOT_TENTATIVE    = 1,  // reduced right bars (early, may repaint)
   MDX_PIVOT_HYBRID       = 2   // emit early + re-validate on confirmation
  };

//+------------------------------------------------------------------+
//| Alert throttling                                                  |
//+------------------------------------------------------------------+
enum ENUM_MDX_ALERTMODE
  {
   MDX_ALERT_ONCE_PER_BAR = 0,
   MDX_ALERT_EVERY_SIGNAL = 1
  };

//+------------------------------------------------------------------+
//| A detected pivot (price + oscillator snapshot)                    |
//+------------------------------------------------------------------+
struct MDXPivot
  {
   int      bar;                       // shift-independent absolute index
   datetime time;                      // bar open time (stable key)
   double   price;                     // high for peaks, low for troughs
   double   osc[MDX_MAX_OSC];          // oscillator values at that bar
   bool     oscValid[MDX_MAX_OSC];     // per-oscillator validity flag
   bool     confirmed;                 // right-side bars fully closed?
   int      atrBars;                   // ATR-normalised age helper
  };

//+------------------------------------------------------------------+
//| Result of a single divergence evaluation                          |
//+------------------------------------------------------------------+
struct MDXResult
  {
   ENUM_MDX_DIVTYPE type;
   double           score;             // 0..100 composite confidence
   int              agree;             // number of agreeing oscillators
   int              conflict;          // number of contradicting oscillators
   int              barIndex;          // bar the marker belongs to
   datetime         barTime;
   double           price;
   int              mask;              // bitmask of agreeing oscillators
   bool             tentative;         // produced from an unconfirmed pivot
  };

//+------------------------------------------------------------------+
//| Reset helpers                                                     |
//+------------------------------------------------------------------+
void MDX_ResetPivot(MDXPivot &p)
  {
   p.bar       = -1;
   p.time      = 0;
   p.price     = 0.0;
   p.confirmed = false;
   p.atrBars   = 0;
   for(int i=0; i<MDX_MAX_OSC; i++)
     {
      p.osc[i]      = 0.0;
      p.oscValid[i] = false;
     }
  }

void MDX_ResetResult(MDXResult &r)
  {
   r.type      = MDX_DIV_NONE;
   r.score     = 0.0;
   r.agree     = 0;
   r.conflict  = 0;
   r.barIndex  = -1;
   r.barTime   = 0;
   r.price     = 0.0;
   r.mask      = 0;
   r.tentative = false;
  }

//+------------------------------------------------------------------+
//| Small math helpers used across modules                            |
//+------------------------------------------------------------------+
double MDX_Clamp(const double v,const double lo,const double hi)
  {
   if(v<lo) return(lo);
   if(v>hi) return(hi);
   return(v);
  }

bool MDX_IsBull(const ENUM_MDX_DIVTYPE t)
  {
   return(t==MDX_DIV_REG_BULL || t==MDX_DIV_HID_BULL);
  }

bool MDX_IsBear(const ENUM_MDX_DIVTYPE t)
  {
   return(t==MDX_DIV_REG_BEAR || t==MDX_DIV_HID_BEAR);
  }

bool MDX_IsHidden(const ENUM_MDX_DIVTYPE t)
  {
   return(t==MDX_DIV_HID_BULL || t==MDX_DIV_HID_BEAR);
  }

string MDX_DivName(const ENUM_MDX_DIVTYPE t)
  {
   switch(t)
     {
      case MDX_DIV_REG_BULL: return("Regular Bullish");
      case MDX_DIV_REG_BEAR: return("Regular Bearish");
      case MDX_DIV_HID_BULL: return("Hidden Bullish");
      case MDX_DIV_HID_BEAR: return("Hidden Bearish");
     }
   return("None");
  }

string MDX_OscName(const int idx)
  {
   switch(idx)
     {
      case MDX_OSC_RSI:   return("RSI");
      case MDX_OSC_CCI:   return("CCI");
      case MDX_OSC_MOM:   return("MOM");
      case MDX_OSC_STOCH: return("STO");
      case MDX_OSC_MACD:  return("MACD");
     }
   return("?");
  }


//==================================================================
//  SECTION 2 : MDX_Oscillators  (oscillator bank class)
//==================================================================
//+------------------------------------------------------------------+
//| Configuration block for the oscillator bank                       |
//+------------------------------------------------------------------+
struct MDXOscConfig
  {
   //--- enable flags
   bool   useRSI;
   bool   useCCI;
   bool   useMOM;
   bool   useSTO;
   bool   useMACD;
   //--- RSI
   int    rsiPeriod;
   ENUM_APPLIED_PRICE rsiPrice;
   //--- CCI
   int    cciPeriod;
   ENUM_APPLIED_PRICE cciPrice;
   //--- Momentum
   int    momPeriod;
   ENUM_APPLIED_PRICE momPrice;
   //--- Stochastic
   int    stoK;
   int    stoD;
   int    stoSlow;
   ENUM_STO_PRICE stoPriceField;
   //--- MACD
   int    macdFast;
   int    macdSlow;
   int    macdSignal;
   ENUM_APPLIED_PRICE macdPrice;
   bool   macdUseHistogram;   // true = main-signal histogram, false = main line
  };

//+------------------------------------------------------------------+
//| Oscillator bank                                                   |
//+------------------------------------------------------------------+
class CMDXOscillatorBank
  {
private:
   MDXOscConfig      m_cfg;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;

   int               m_hRSI;
   int               m_hCCI;
   int               m_hMOM;
   int               m_hSTO;
   int               m_hMACD;
   int               m_hMACDsig;   // only used when histogram mode requested

   //--- series buffers (index 0 == oldest, we use as-series = false layout)
   double            m_bufRSI[];
   double            m_bufCCI[];
   double            m_bufMOM[];
   double            m_bufSTO[];
   double            m_bufMACD[];
   double            m_bufMACDs[];

   bool              m_ready[MDX_MAX_OSC];
   int               m_copied;

public:
                     CMDXOscillatorBank(void);
                    ~CMDXOscillatorBank(void);

   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,const MDXOscConfig &cfg);
   void              Deinit(void);

   //--- copy 'count' most recent values, non-series layout aligned to rates arrays
   bool              Refresh(const int ratesTotal,const int needed);

   //--- accessors: 'i' is a NON-series index (0 == oldest bar in rates arrays)
   bool              Enabled(const int osc) const;
   bool              Ready(const int osc)   const;
   double            Value(const int osc,const int i) const;

   //--- how many bars of oscillator history are currently valid
   int               Copied(void) const { return(m_copied); }

   //--- minimum bars required before values are meaningful
   int               WarmupBars(void) const;

   //--- normalisation: convert raw oscillator delta into a 0..1 "significance"
   double            NormalizeDelta(const int osc,const double delta,const double atrPoints) const;

   //--- typical full-scale range of each oscillator (used for slope scoring)
   double            ScaleHint(const int osc) const;
  };

//+------------------------------------------------------------------+
CMDXOscillatorBank::CMDXOscillatorBank(void)
  {
   m_hRSI=INVALID_HANDLE; m_hCCI=INVALID_HANDLE; m_hMOM=INVALID_HANDLE;
   m_hSTO=INVALID_HANDLE; m_hMACD=INVALID_HANDLE; m_hMACDsig=INVALID_HANDLE;
   m_copied=0;
   m_symbol=_Symbol;
   m_tf=PERIOD_CURRENT;
   for(int i=0;i<MDX_MAX_OSC;i++) m_ready[i]=false;
  }
//+------------------------------------------------------------------+
CMDXOscillatorBank::~CMDXOscillatorBank(void)
  {
   Deinit();
  }
//+------------------------------------------------------------------+
void CMDXOscillatorBank::Deinit(void)
  {
   if(m_hRSI!=INVALID_HANDLE)    { IndicatorRelease(m_hRSI);    m_hRSI=INVALID_HANDLE; }
   if(m_hCCI!=INVALID_HANDLE)    { IndicatorRelease(m_hCCI);    m_hCCI=INVALID_HANDLE; }
   if(m_hMOM!=INVALID_HANDLE)    { IndicatorRelease(m_hMOM);    m_hMOM=INVALID_HANDLE; }
   if(m_hSTO!=INVALID_HANDLE)    { IndicatorRelease(m_hSTO);    m_hSTO=INVALID_HANDLE; }
   if(m_hMACD!=INVALID_HANDLE)   { IndicatorRelease(m_hMACD);   m_hMACD=INVALID_HANDLE; }
   if(m_hMACDsig!=INVALID_HANDLE){ IndicatorRelease(m_hMACDsig);m_hMACDsig=INVALID_HANDLE; }
  }
//+------------------------------------------------------------------+
bool CMDXOscillatorBank::Init(const string symbol,const ENUM_TIMEFRAMES tf,const MDXOscConfig &cfg)
  {
   Deinit();
   m_cfg=cfg;
   m_symbol=symbol;
   m_tf=tf;

   bool ok=true;

   if(m_cfg.useRSI)
     {
      m_hRSI=iRSI(m_symbol,m_tf,m_cfg.rsiPeriod,m_cfg.rsiPrice);
      if(m_hRSI==INVALID_HANDLE){ Print("MDX: iRSI handle failed"); ok=false; }
     }
   if(m_cfg.useCCI)
     {
      m_hCCI=iCCI(m_symbol,m_tf,m_cfg.cciPeriod,m_cfg.cciPrice);
      if(m_hCCI==INVALID_HANDLE){ Print("MDX: iCCI handle failed"); ok=false; }
     }
   if(m_cfg.useMOM)
     {
      m_hMOM=iMomentum(m_symbol,m_tf,m_cfg.momPeriod,m_cfg.momPrice);
      if(m_hMOM==INVALID_HANDLE){ Print("MDX: iMomentum handle failed"); ok=false; }
     }
   if(m_cfg.useSTO)
     {
      m_hSTO=iStochastic(m_symbol,m_tf,m_cfg.stoK,m_cfg.stoD,m_cfg.stoSlow,
                         MODE_SMA,m_cfg.stoPriceField);
      if(m_hSTO==INVALID_HANDLE){ Print("MDX: iStochastic handle failed"); ok=false; }
     }
   if(m_cfg.useMACD)
     {
      m_hMACD=iMACD(m_symbol,m_tf,m_cfg.macdFast,m_cfg.macdSlow,m_cfg.macdSignal,m_cfg.macdPrice);
      if(m_hMACD==INVALID_HANDLE){ Print("MDX: iMACD handle failed"); ok=false; }
     }

   ArraySetAsSeries(m_bufRSI,false);
   ArraySetAsSeries(m_bufCCI,false);
   ArraySetAsSeries(m_bufMOM,false);
   ArraySetAsSeries(m_bufSTO,false);
   ArraySetAsSeries(m_bufMACD,false);
   ArraySetAsSeries(m_bufMACDs,false);

   return(ok);
  }
//+------------------------------------------------------------------+
int CMDXOscillatorBank::WarmupBars(void) const
  {
   int w=10;
   if(m_cfg.useRSI)  w=MathMax(w,m_cfg.rsiPeriod+5);
   if(m_cfg.useCCI)  w=MathMax(w,m_cfg.cciPeriod+5);
   if(m_cfg.useMOM)  w=MathMax(w,m_cfg.momPeriod+5);
   if(m_cfg.useSTO)  w=MathMax(w,m_cfg.stoK+m_cfg.stoD+m_cfg.stoSlow+5);
   if(m_cfg.useMACD) w=MathMax(w,m_cfg.macdSlow+m_cfg.macdSignal+5);
   return(w);
  }
//+------------------------------------------------------------------+
//| Copy oscillator data.                                             |
//| We copy the most recent 'needed' bars and place them at the tail  |
//| of a ratesTotal-sized array so that indexing matches the rates    |
//| arrays exactly (non-series, 0 == oldest).                         |
//+------------------------------------------------------------------+
bool CMDXOscillatorBank::Refresh(const int ratesTotal,const int needed)
  {
   int cnt=MathMin(ratesTotal,MathMax(needed,WarmupBars()+50));
   if(cnt<=0) return(false);
   m_copied=cnt;
   int start=ratesTotal-cnt;             // first absolute index we will fill

   for(int i=0;i<MDX_MAX_OSC;i++) m_ready[i]=false;

   //--- helper macro-ish inline copy
   //    CopyBuffer with (start_pos measured from the newest bar) is avoided:
   //    we use the "start,count" form relative to the current series.
   if(m_cfg.useRSI && m_hRSI!=INVALID_HANDLE)
     {
      if(ArraySize(m_bufRSI)!=ratesTotal) ArrayResize(m_bufRSI,ratesTotal);
      double tmp[];
      ArraySetAsSeries(tmp,false);
      if(CopyBuffer(m_hRSI,0,0,cnt,tmp)==cnt)
        {
         for(int k=0;k<cnt;k++) m_bufRSI[start+k]=tmp[k];
         m_ready[MDX_OSC_RSI]=true;
        }
     }

   if(m_cfg.useCCI && m_hCCI!=INVALID_HANDLE)
     {
      if(ArraySize(m_bufCCI)!=ratesTotal) ArrayResize(m_bufCCI,ratesTotal);
      double tmp[];
      ArraySetAsSeries(tmp,false);
      if(CopyBuffer(m_hCCI,0,0,cnt,tmp)==cnt)
        {
         for(int k=0;k<cnt;k++) m_bufCCI[start+k]=tmp[k];
         m_ready[MDX_OSC_CCI]=true;
        }
     }

   if(m_cfg.useMOM && m_hMOM!=INVALID_HANDLE)
     {
      if(ArraySize(m_bufMOM)!=ratesTotal) ArrayResize(m_bufMOM,ratesTotal);
      double tmp[];
      ArraySetAsSeries(tmp,false);
      if(CopyBuffer(m_hMOM,0,0,cnt,tmp)==cnt)
        {
         for(int k=0;k<cnt;k++) m_bufMOM[start+k]=tmp[k];
         m_ready[MDX_OSC_MOM]=true;
        }
     }

   if(m_cfg.useSTO && m_hSTO!=INVALID_HANDLE)
     {
      if(ArraySize(m_bufSTO)!=ratesTotal) ArrayResize(m_bufSTO,ratesTotal);
      double tmp[];
      ArraySetAsSeries(tmp,false);
      //--- buffer 0 = main %K line (faster than %D, better for early divergence)
      if(CopyBuffer(m_hSTO,0,0,cnt,tmp)==cnt)
        {
         for(int k=0;k<cnt;k++) m_bufSTO[start+k]=tmp[k];
         m_ready[MDX_OSC_STOCH]=true;
        }
     }

   if(m_cfg.useMACD && m_hMACD!=INVALID_HANDLE)
     {
      if(ArraySize(m_bufMACD)!=ratesTotal)  ArrayResize(m_bufMACD,ratesTotal);
      if(ArraySize(m_bufMACDs)!=ratesTotal) ArrayResize(m_bufMACDs,ratesTotal);
      double tmpM[],tmpS[];
      ArraySetAsSeries(tmpM,false);
      ArraySetAsSeries(tmpS,false);
      bool okM=(CopyBuffer(m_hMACD,0,0,cnt,tmpM)==cnt);
      bool okS=true;
      if(m_cfg.macdUseHistogram) okS=(CopyBuffer(m_hMACD,1,0,cnt,tmpS)==cnt);
      if(okM && okS)
        {
         for(int k=0;k<cnt;k++)
           {
            m_bufMACD[start+k]=tmpM[k];
            m_bufMACDs[start+k]=(m_cfg.macdUseHistogram? tmpS[k] : 0.0);
           }
         m_ready[MDX_OSC_MACD]=true;
        }
     }

   return(true);
  }
//+------------------------------------------------------------------+
bool CMDXOscillatorBank::Enabled(const int osc) const
  {
   switch(osc)
     {
      case MDX_OSC_RSI:   return(m_cfg.useRSI);
      case MDX_OSC_CCI:   return(m_cfg.useCCI);
      case MDX_OSC_MOM:   return(m_cfg.useMOM);
      case MDX_OSC_STOCH: return(m_cfg.useSTO);
      case MDX_OSC_MACD:  return(m_cfg.useMACD);
     }
   return(false);
  }
//+------------------------------------------------------------------+
bool CMDXOscillatorBank::Ready(const int osc) const
  {
   if(osc<0 || osc>=MDX_MAX_OSC) return(false);
   return(m_ready[osc]);
  }
//+------------------------------------------------------------------+
double CMDXOscillatorBank::Value(const int osc,const int i) const
  {
   if(i<0) return(EMPTY_VALUE);
   switch(osc)
     {
      case MDX_OSC_RSI:
         if(!m_ready[MDX_OSC_RSI] || i>=ArraySize(m_bufRSI)) return(EMPTY_VALUE);
         return(m_bufRSI[i]);
      case MDX_OSC_CCI:
         if(!m_ready[MDX_OSC_CCI] || i>=ArraySize(m_bufCCI)) return(EMPTY_VALUE);
         return(m_bufCCI[i]);
      case MDX_OSC_MOM:
         if(!m_ready[MDX_OSC_MOM] || i>=ArraySize(m_bufMOM)) return(EMPTY_VALUE);
         return(m_bufMOM[i]);
      case MDX_OSC_STOCH:
         if(!m_ready[MDX_OSC_STOCH] || i>=ArraySize(m_bufSTO)) return(EMPTY_VALUE);
         return(m_bufSTO[i]);
      case MDX_OSC_MACD:
        {
         if(!m_ready[MDX_OSC_MACD] || i>=ArraySize(m_bufMACD)) return(EMPTY_VALUE);
         if(m_cfg.macdUseHistogram) return(m_bufMACD[i]-m_bufMACDs[i]);
         return(m_bufMACD[i]);
        }
     }
   return(EMPTY_VALUE);
  }
//+------------------------------------------------------------------+
//| Rough full-scale span of each oscillator. Used to convert a raw   |
//| delta into a dimensionless significance figure.                   |
//+------------------------------------------------------------------+
double CMDXOscillatorBank::ScaleHint(const int osc) const
  {
   switch(osc)
     {
      case MDX_OSC_RSI:   return(100.0);
      case MDX_OSC_CCI:   return(400.0);
      case MDX_OSC_STOCH: return(100.0);
      case MDX_OSC_MOM:   return(2.0);   // Momentum oscillates around 100
      case MDX_OSC_MACD:  return(0.0);   // dynamic - handled by caller via ATR
     }
   return(1.0);
  }
//+------------------------------------------------------------------+
//| Convert an oscillator delta into 0..1 significance.               |
//| MACD/Momentum are price-scaled so we normalise them with ATR.     |
//+------------------------------------------------------------------+
double CMDXOscillatorBank::NormalizeDelta(const int osc,const double delta,const double atrPoints) const
  {
   double d=MathAbs(delta);
   double denom;

   switch(osc)
     {
      case MDX_OSC_RSI:   denom=6.0;   break;   // 6 RSI points  = "full" signal
      case MDX_OSC_CCI:   denom=40.0;  break;   // 40 CCI points
      case MDX_OSC_STOCH: denom=10.0;  break;   // 10 %K points
      case MDX_OSC_MOM:   denom=0.15;  break;   // 0.15 momentum points
      case MDX_OSC_MACD:
        {
         //--- MACD is in price units; scale against ATR so it is symbol-agnostic
         double a=(atrPoints>0.0? atrPoints : _Point*10.0);
         denom=a*0.15;
         if(denom<=0.0) denom=_Point;
         break;
        }
      default: denom=1.0;
     }

   if(denom<=0.0) return(0.0);
   return(MDX_Clamp(d/denom,0.0,1.0));
  }


//==================================================================
//  SECTION 3 : MDX_Pivots  (swing / pivot detection)
//==================================================================
//+------------------------------------------------------------------+
//| Ring buffer of pivots for one side (highs or lows)                |
//+------------------------------------------------------------------+
class CMDXPivotSeries
  {
private:
   MDXPivot          m_p[MDX_MAX_PIVOTS];
   int               m_count;    // total pushed (monotonic)
   int               m_head;     // next write slot

public:
                     CMDXPivotSeries(void){ Clear(); }

   void              Clear(void)
     {
      m_count=0; m_head=0;
      for(int i=0;i<MDX_MAX_PIVOTS;i++) MDX_ResetPivot(m_p[i]);
     }

   int               Count(void) const { return(m_count); }

   //--- Get(0) = most recent pivot, Get(1) = one before, ...
   bool              Get(const int back,MDXPivot &out) const
     {
      if(back<0 || back>=MathMin(m_count,MDX_MAX_PIVOTS)) return(false);
      int idx=(m_head-1-back+2*MDX_MAX_PIVOTS)%MDX_MAX_PIVOTS;
      out=m_p[idx];
      return(true);
     }

   //--- direct mutable access to the most recent pivot
   bool              UpdateLast(const MDXPivot &in)
     {
      if(m_count<=0) return(false);
      int idx=(m_head-1+MDX_MAX_PIVOTS)%MDX_MAX_PIVOTS;
      m_p[idx]=in;
      return(true);
     }

   void              Push(const MDXPivot &in)
     {
      m_p[m_head]=in;
      m_head=(m_head+1)%MDX_MAX_PIVOTS;
      m_count++;
     }

   //--- drop pivots newer than (or equal to) a given bar index.
   //    Used when a tentative pivot is invalidated by later price action.
   void              DropFrom(const int barIndex)
     {
      while(m_count>0)
        {
         int idx=(m_head-1+MDX_MAX_PIVOTS)%MDX_MAX_PIVOTS;
         if(m_p[idx].bar>=barIndex)
           {
            MDX_ResetPivot(m_p[idx]);
            m_head=idx;
            m_count--;
           }
         else break;
        }
     }
  };

//+------------------------------------------------------------------+
//| Pivot detector configuration                                      |
//+------------------------------------------------------------------+
struct MDXPivotConfig
  {
   int    leftBars;          // bars to the left that must be lower/higher
   int    rightBarsConf;     // right bars for a CONFIRMED pivot
   int    rightBarsTent;     // right bars for a TENTATIVE pivot (< conf)
   ENUM_MDX_PIVOTPOLICY policy;
   bool   useWicks;          // true = high/low, false = close-based extremes
   double minAtrDisplace;    // tentative pivot needs this * ATR of retrace
   bool   requireStrictLeft; // strict > / < on the left side
  };

//+------------------------------------------------------------------+
//| Pivot detector                                                    |
//+------------------------------------------------------------------+
class CMDXPivotDetector
  {
private:
   MDXPivotConfig    m_cfg;

   double            PriceHigh(const double &high[],const double &close[],
                               const double &open[],const int i) const
     {
      if(m_cfg.useWicks) return(high[i]);
      return(MathMax(open[i],close[i]));
     }
   double            PriceLow(const double &low[],const double &close[],
                              const double &open[],const int i) const
     {
      if(m_cfg.useWicks) return(low[i]);
      return(MathMin(open[i],close[i]));
     }

public:
                     CMDXPivotDetector(void){}

   void              SetConfig(const MDXPivotConfig &c){ m_cfg=c; }
   MDXPivotConfig    Config(void) const { return(m_cfg); }

   //--- Is bar 'i' a swing high given 'right' bars of confirmation?
   bool              IsSwingHigh(const double &high[],const double &open[],
                                 const double &close[],const int i,
                                 const int total,const int right) const
     {
      if(i-m_cfg.leftBars<0)      return(false);
      if(i+right>total-1)         return(false);

      double pv=PriceHigh(high,close,open,i);

      for(int k=1;k<=m_cfg.leftBars;k++)
        {
         double v=PriceHigh(high,close,open,i-k);
         if(m_cfg.requireStrictLeft){ if(v>=pv) return(false); }
         else                       { if(v> pv) return(false); }
        }
      for(int k=1;k<=right;k++)
        {
         double v=PriceHigh(high,close,open,i+k);
         if(v>pv) return(false);          // non-strict on the right
        }
      return(true);
     }

   //--- Is bar 'i' a swing low?
   bool              IsSwingLow(const double &low[],const double &open[],
                                const double &close[],const int i,
                                const int total,const int right) const
     {
      if(i-m_cfg.leftBars<0)      return(false);
      if(i+right>total-1)         return(false);

      double pv=PriceLow(low,close,open,i);

      for(int k=1;k<=m_cfg.leftBars;k++)
        {
         double v=PriceLow(low,close,open,i-k);
         if(m_cfg.requireStrictLeft){ if(v<=pv) return(false); }
         else                       { if(v< pv) return(false); }
        }
      for(int k=1;k<=right;k++)
        {
         double v=PriceLow(low,close,open,i+k);
         if(v<pv) return(false);
        }
      return(true);
     }

   //--- ATR displacement test used to qualify tentative pivots.
   //    Requires price to have travelled away from the pivot by a
   //    meaningful fraction of ATR, filtering out micro-noise pivots.
   bool              DisplacementOK(const double pivotPrice,const double refPrice,
                                    const double atr) const
     {
      if(m_cfg.minAtrDisplace<=0.0) return(true);
      if(atr<=0.0)                  return(true);
      return(MathAbs(refPrice-pivotPrice)>=atr*m_cfg.minAtrDisplace);
     }

   //--- Effective right-bar count for the current policy
   int               RightBarsFor(const bool tentative) const
     {
      if(tentative) return(MathMax(1,m_cfg.rightBarsTent));
      return(MathMax(1,m_cfg.rightBarsConf));
     }
  };


//==================================================================
//  SECTION 4 : MDX_Scoring  (weighted composite scoring engine)
//==================================================================
//+------------------------------------------------------------------+
//| Scoring configuration                                             |
//+------------------------------------------------------------------+
struct MDXScoreConfig
  {
   double weight[MDX_MAX_OSC];   // per-oscillator weight
   double conflictPenalty;       // multiplier applied to conflicting votes
   double minScore;              // 0..100 threshold to emit a signal
   int    minAgree;              // minimum number of agreeing oscillators
   double noiseBandPct;          // % of "denominator" below which vote = neutral
   double tentativePenalty;      // multiplier for unconfirmed pivots (0..1)
   double hiddenPenalty;         // multiplier for hidden divergence (0..1)
   double trendPenalty;          // multiplier when trend filter disagrees
   double volPenalty;            // multiplier when volatility filter disagrees
   double priceQualityWeight;    // how much price-leg quality contributes
   double slopeQualityWeight;    // how much oscillator magnitude contributes
  };

//+------------------------------------------------------------------+
//| Scoring engine                                                    |
//+------------------------------------------------------------------+
class CMDXScorer
  {
private:
   MDXScoreConfig    m_cfg;

public:
                     CMDXScorer(void){}
   void              SetConfig(const MDXScoreConfig &c){ m_cfg=c; }
   MDXScoreConfig    Config(void) const { return(m_cfg); }

   double            TotalWeight(const CMDXOscillatorBank &bank) const
     {
      double t=0.0;
      for(int o=0;o<MDX_MAX_OSC;o++)
         if(bank.Enabled(o) && bank.Ready(o)) t+=m_cfg.weight[o];
      return(t);
     }

   //+---------------------------------------------------------------+
   //| Evaluate a two-pivot candidate.                                |
   //|  p1 = older pivot, p2 = newer pivot                            |
   //|  wantOscUp:  true  -> divergence requires oscillator to rise   |
   //|              false -> requires oscillator to fall              |
   //+---------------------------------------------------------------+
   bool              Evaluate(const CMDXOscillatorBank &bank,
                              const MDXPivot &p1,const MDXPivot &p2,
                              const bool wantOscUp,
                              const double atr,
                              double &scoreOut,int &agreeOut,
                              int &conflictOut,int &maskOut) const
     {
      double sumW=0.0, sumPos=0.0, sumNeg=0.0;
      int    agree=0, conflict=0, mask=0;

      for(int o=0;o<MDX_MAX_OSC;o++)
        {
         if(!bank.Enabled(o) || !bank.Ready(o)) continue;
         if(!p1.oscValid[o] || !p2.oscValid[o]) continue;

         double w=m_cfg.weight[o];
         if(w<=0.0) continue;
         sumW+=w;

         double delta=p2.osc[o]-p1.osc[o];
         double sig=bank.NormalizeDelta(o,delta,atr);   // 0..1 magnitude

         //--- noise band: too small a move => abstain
         if(sig < m_cfg.noiseBandPct*0.01)
            continue;

         bool up=(delta>0.0);
         if(up==wantOscUp)
           {
            agree++;
            mask|=(1<<o);
            sumPos+=w*(0.35+0.65*sig);   // partial credit + magnitude bonus
           }
         else
           {
            conflict++;
            sumNeg+=w*(0.35+0.65*sig)*m_cfg.conflictPenalty;
           }
        }

      agreeOut=agree;
      conflictOut=conflict;
      maskOut=mask;

      if(sumW<=0.0){ scoreOut=0.0; return(false); }

      double raw=(sumPos-sumNeg)/sumW;         // -inf..1 (typically -1..1)
      raw=MDX_Clamp(raw,0.0,1.0);
      scoreOut=raw*100.0;
      return(true);
     }

   //+---------------------------------------------------------------+
   //| Price-leg quality: how clean is the price displacement?        |
   //| Legs that barely differ from each other are weak evidence.     |
   //+---------------------------------------------------------------+
   double            PriceQuality(const double p1,const double p2,const double atr) const
     {
      if(atr<=0.0) return(0.6);
      double d=MathAbs(p2-p1);
      //--- 0.5*ATR of separation is treated as a "full quality" leg
      return(MDX_Clamp(d/(atr*0.5),0.15,1.0));
     }

   //+---------------------------------------------------------------+
   //| Apply all multiplicative modifiers and return final 0..100     |
   //+---------------------------------------------------------------+
   double            Finalize(const double baseScore,
                              const double priceQuality,
                              const bool tentative,
                              const bool hidden,
                              const bool trendDisagrees,
                              const bool volDisagrees,
                              const int barGap,
                              const int idealMinGap,
                              const int idealMaxGap) const
     {
      double s=baseScore;

      //--- blend in price-leg quality
      double pw=MDX_Clamp(m_cfg.priceQualityWeight,0.0,1.0);
      s=s*((1.0-pw)+pw*priceQuality);

      //--- geometry: penalise legs that are too close or stretched
      if(barGap<idealMinGap)      s*=0.80;
      else if(barGap>idealMaxGap) s*=0.85;

      if(tentative)      s*=MDX_Clamp(m_cfg.tentativePenalty,0.1,1.0);
      if(hidden)         s*=MDX_Clamp(m_cfg.hiddenPenalty,0.1,1.0);
      if(trendDisagrees) s*=MDX_Clamp(m_cfg.trendPenalty,0.1,1.0);
      if(volDisagrees)   s*=MDX_Clamp(m_cfg.volPenalty,0.1,1.0);

      return(MDX_Clamp(s,0.0,100.0));
     }

   bool              PassesThreshold(const double score,const int agree) const
     {
      if(agree<m_cfg.minAgree) return(false);
      return(score>=m_cfg.minScore);
     }
  };


//==================================================================
//  SECTION 5 : MDX_Filters  (trend / volatility / session filters)
//==================================================================
//+------------------------------------------------------------------+
//| Trend filter                                                      |
//+------------------------------------------------------------------+
class CMDXTrendFilter
  {
private:
   ENUM_MDX_TRENDFILTER m_type;
   int               m_hFast;
   int               m_hSlow;
   int               m_fastPeriod;
   int               m_slowPeriod;
   int               m_slopeBars;
   double            m_fast[];
   double            m_slow[];
   bool              m_ready;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;

public:
                     CMDXTrendFilter(void)
     {
      m_type=MDX_TREND_OFF; m_hFast=INVALID_HANDLE; m_hSlow=INVALID_HANDLE;
      m_ready=false; m_fastPeriod=21; m_slowPeriod=55; m_slopeBars=3;
      m_symbol=_Symbol; m_tf=PERIOD_CURRENT;
      ArraySetAsSeries(m_fast,false);
      ArraySetAsSeries(m_slow,false);
     }
                    ~CMDXTrendFilter(void){ Deinit(); }

   void              Deinit(void)
     {
      if(m_hFast!=INVALID_HANDLE){ IndicatorRelease(m_hFast); m_hFast=INVALID_HANDLE; }
      if(m_hSlow!=INVALID_HANDLE){ IndicatorRelease(m_hSlow); m_hSlow=INVALID_HANDLE; }
     }

   bool              Init(const string sym,const ENUM_TIMEFRAMES tf,
                          const ENUM_MDX_TRENDFILTER type,
                          const int fastP,const int slowP,const int slopeBars,
                          const ENUM_APPLIED_PRICE price)
     {
      Deinit();
      m_symbol=sym; m_tf=tf; m_type=type;
      m_fastPeriod=MathMax(2,fastP);
      m_slowPeriod=MathMax(2,slowP);
      m_slopeBars=MathMax(1,slopeBars);

      if(m_type==MDX_TREND_EMA || m_type==MDX_TREND_EMA_CROSS)
        {
         m_hFast=iMA(m_symbol,m_tf,m_fastPeriod,0,MODE_EMA,price);
         if(m_hFast==INVALID_HANDLE) return(false);
         if(m_type==MDX_TREND_EMA_CROSS)
           {
            m_hSlow=iMA(m_symbol,m_tf,m_slowPeriod,0,MODE_EMA,price);
            if(m_hSlow==INVALID_HANDLE) return(false);
           }
        }
      return(true);
     }

   int               WarmupBars(void) const
     {
      if(m_type==MDX_TREND_OFF) return(0);
      return(MathMax(m_slowPeriod,m_fastPeriod)+m_slopeBars+5);
     }

   bool              Refresh(const int ratesTotal,const int needed)
     {
      m_ready=false;
      if(m_type!=MDX_TREND_EMA && m_type!=MDX_TREND_EMA_CROSS) return(true);

      int cnt=MathMin(ratesTotal,MathMax(needed,WarmupBars()+50));
      if(cnt<=0) return(false);
      int start=ratesTotal-cnt;

      if(ArraySize(m_fast)!=ratesTotal) ArrayResize(m_fast,ratesTotal);
      double tmp[];
      ArraySetAsSeries(tmp,false);
      if(m_hFast==INVALID_HANDLE || CopyBuffer(m_hFast,0,0,cnt,tmp)!=cnt) return(false);
      for(int k=0;k<cnt;k++) m_fast[start+k]=tmp[k];

      if(m_type==MDX_TREND_EMA_CROSS)
        {
         if(ArraySize(m_slow)!=ratesTotal) ArrayResize(m_slow,ratesTotal);
         if(m_hSlow==INVALID_HANDLE || CopyBuffer(m_hSlow,0,0,cnt,tmp)!=cnt) return(false);
         for(int k=0;k<cnt;k++) m_slow[start+k]=tmp[k];
        }

      m_ready=true;
      return(true);
     }

   //--- +1 bullish, -1 bearish, 0 neutral / unavailable
   int               Bias(const int i,const double &close[],
                          const double &high[],const double &low[]) const
     {
      switch(m_type)
        {
         case MDX_TREND_OFF:
            return(0);

         case MDX_TREND_EMA:
           {
            if(!m_ready || i<m_slopeBars || i>=ArraySize(m_fast)) return(0);
            double now=m_fast[i];
            double prev=m_fast[i-m_slopeBars];
            if(now==0.0 || prev==0.0) return(0);
            bool slopeUp=(now>prev);
            bool above=(close[i]>now);
            if(slopeUp && above)   return(1);
            if(!slopeUp && !above) return(-1);
            return(0);
           }

         case MDX_TREND_EMA_CROSS:
           {
            if(!m_ready || i<m_slopeBars) return(0);
            if(i>=ArraySize(m_fast) || i>=ArraySize(m_slow)) return(0);
            double f=m_fast[i], s=m_slow[i];
            if(f==0.0 || s==0.0) return(0);
            if(f>s) return(1);
            if(f<s) return(-1);
            return(0);
           }

         case MDX_TREND_STRUCTURE:
           {
            //--- lightweight structural read: compare the two most recent
            //    rolling extremes over a short and a medium window.
            int shortW=8, longW=24;
            if(i<longW) return(0);
            double hS=high[i],lS=low[i],hL=high[i],lL=low[i];
            for(int k=0;k<shortW;k++)
              {
               if(high[i-k]>hS) hS=high[i-k];
               if(low[i-k] <lS) lS=low[i-k];
              }
            for(int k=0;k<longW;k++)
              {
               if(high[i-k]>hL) hL=high[i-k];
               if(low[i-k] <lL) lL=low[i-k];
              }
            double range=hL-lL;
            if(range<=0.0) return(0);
            double pos=(close[i]-lL)/range;   // 0..1 position in the range
            bool higherLows=(lS>lL+range*0.15);
            bool lowerHighs=(hS<hL-range*0.15);
            if(pos>0.60 && higherLows) return(1);
            if(pos<0.40 && lowerHighs) return(-1);
            return(0);
           }
        }
      return(0);
     }
  };

//+------------------------------------------------------------------+
//| Volatility filter (ATR)                                           |
//+------------------------------------------------------------------+
class CMDXVolFilter
  {
private:
   int               m_handle;
   int               m_period;
   double            m_atr[];
   bool              m_ready;
   bool              m_enabled;
   double            m_minMult;    // ATR must be >= minMult * avgATR
   double            m_maxMult;    // ATR must be <= maxMult * avgATR (0 = off)
   int               m_avgLen;

public:
                     CMDXVolFilter(void)
     {
      m_handle=INVALID_HANDLE; m_period=14; m_ready=false; m_enabled=false;
      m_minMult=0.6; m_maxMult=0.0; m_avgLen=50;
      ArraySetAsSeries(m_atr,false);
     }
                    ~CMDXVolFilter(void){ Deinit(); }

   void              Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE){ IndicatorRelease(m_handle); m_handle=INVALID_HANDLE; }
     }

   //--- ATR is ALWAYS created (used internally for normalisation),
   //    'enabled' only controls whether it can veto/penalise signals.
   bool              Init(const string sym,const ENUM_TIMEFRAMES tf,const int period,
                          const bool enabled,const double minMult,const double maxMult,
                          const int avgLen)
     {
      Deinit();
      m_period=MathMax(2,period);
      m_enabled=enabled;
      m_minMult=minMult;
      m_maxMult=maxMult;
      m_avgLen=MathMax(5,avgLen);
      m_handle=iATR(sym,tf,m_period);
      return(m_handle!=INVALID_HANDLE);
     }

   int               WarmupBars(void) const { return(m_period+m_avgLen+5); }

   bool              Refresh(const int ratesTotal,const int needed)
     {
      m_ready=false;
      if(m_handle==INVALID_HANDLE) return(false);
      int cnt=MathMin(ratesTotal,MathMax(needed,WarmupBars()+50));
      if(cnt<=0) return(false);
      int start=ratesTotal-cnt;
      if(ArraySize(m_atr)!=ratesTotal) ArrayResize(m_atr,ratesTotal);
      double tmp[];
      ArraySetAsSeries(tmp,false);
      if(CopyBuffer(m_handle,0,0,cnt,tmp)!=cnt) return(false);
      for(int k=0;k<cnt;k++) m_atr[start+k]=tmp[k];
      m_ready=true;
      return(true);
     }

   double            ATR(const int i) const
     {
      if(!m_ready || i<0 || i>=ArraySize(m_atr)) return(0.0);
      return(m_atr[i]);
     }

   double            AvgATR(const int i) const
     {
      if(!m_ready || i<m_avgLen || i>=ArraySize(m_atr)) return(ATR(i));
      double s=0.0;
      for(int k=0;k<m_avgLen;k++) s+=m_atr[i-k];
      return(s/m_avgLen);
     }

   //--- true = volatility regime acceptable
   bool              Pass(const int i) const
     {
      if(!m_enabled) return(true);
      if(!m_ready)   return(true);
      double a=ATR(i);
      double avg=AvgATR(i);
      if(avg<=0.0) return(true);
      if(m_minMult>0.0 && a < avg*m_minMult) return(false);
      if(m_maxMult>0.0 && a > avg*m_maxMult) return(false);
      return(true);
     }
  };

//+------------------------------------------------------------------+
//| Session filter                                                    |
//+------------------------------------------------------------------+
class CMDXSessionFilter
  {
private:
   bool              m_enabled;
   int               m_s1From,m_s1To;   // minutes from midnight (server time)
   int               m_s2From,m_s2To;
   int               m_s3From,m_s3To;
   bool              m_skipFriLate;
   int               m_friCutoff;
   bool              m_skipMonEarly;
   int               m_monOpen;

   static int        ToMinutes(const string hhmm)
     {
      string parts[];
      if(StringSplit(hhmm,':',parts)!=2) return(-1);
      int h=(int)StringToInteger(parts[0]);
      int m=(int)StringToInteger(parts[1]);
      if(h<0||h>23||m<0||m>59) return(-1);
      return(h*60+m);
     }

   static bool       InWindow(const int nowMin,const int from,const int to)
     {
      if(from<0 || to<0)  return(false);
      if(from==to)        return(false);
      if(from<to)         return(nowMin>=from && nowMin<to);
      return(nowMin>=from || nowMin<to);      // wraps midnight
     }

public:
                     CMDXSessionFilter(void)
     {
      m_enabled=false;
      m_s1From=m_s1To=m_s2From=m_s2To=m_s3From=m_s3To=-1;
      m_skipFriLate=false; m_friCutoff=20*60;
      m_skipMonEarly=false; m_monOpen=0;
     }

   void              Init(const bool enabled,
                          const string s1From,const string s1To,
                          const string s2From,const string s2To,
                          const string s3From,const string s3To,
                          const bool skipFriLate,const string friCutoff,
                          const bool skipMonEarly,const string monOpen)
     {
      m_enabled=enabled;
      m_s1From=ToMinutes(s1From); m_s1To=ToMinutes(s1To);
      m_s2From=ToMinutes(s2From); m_s2To=ToMinutes(s2To);
      m_s3From=ToMinutes(s3From); m_s3To=ToMinutes(s3To);
      m_skipFriLate=skipFriLate;
      int fc=ToMinutes(friCutoff);  m_friCutoff=(fc>=0? fc : 20*60);
      m_skipMonEarly=skipMonEarly;
      int mo=ToMinutes(monOpen);    m_monOpen=(mo>=0? mo : 0);
     }

   bool              Pass(const datetime t) const
     {
      if(!m_enabled) return(true);
      MqlDateTime dt;
      TimeToStruct(t,dt);
      int nowMin=dt.hour*60+dt.min;

      if(dt.day_of_week==0 || dt.day_of_week==6) return(false);   // weekend
      if(m_skipFriLate  && dt.day_of_week==5 && nowMin>=m_friCutoff) return(false);
      if(m_skipMonEarly && dt.day_of_week==1 && nowMin< m_monOpen)   return(false);

      bool any=(m_s1From>=0 || m_s2From>=0 || m_s3From>=0);
      if(!any) return(true);

      if(InWindow(nowMin,m_s1From,m_s1To)) return(true);
      if(InWindow(nowMin,m_s2From,m_s2To)) return(true);
      if(InWindow(nowMin,m_s3From,m_s3To)) return(true);
      return(false);
     }
  };


//==================================================================
//  SECTION 6 : MDX_Engine  (orchestrator + signal memory)
//==================================================================
//+------------------------------------------------------------------+
//| Engine configuration                                              |
//+------------------------------------------------------------------+
struct MDXEngineConfig
  {
   ENUM_MDX_DIVMODE  divMode;
   int               maxPivotLookback;   // how many previous pivots to pair with
   int               minBarGap;          // minimum bars between the two pivots
   int               maxBarGap;          // maximum bars between the two pivots
   int               idealMinGap;
   int               idealMaxGap;
   bool              allowMultiPair;     // evaluate several older pivots, keep best
   bool              requireCloseBreak;  // extra confirmation on the signal bar
   double            minPriceDeltaAtr;   // minimum price separation in ATR units
   ENUM_MDX_TRENDMODE trendMode;
  };

//+------------------------------------------------------------------+
//| Signal memory entry (duplicate suppression)                       |
//+------------------------------------------------------------------+
struct MDXSignalKey
  {
   datetime t1;      // older pivot time
   datetime t2;      // newer pivot time
   int      type;    // ENUM_MDX_DIVTYPE
  };

//+------------------------------------------------------------------+
//| The engine                                                        |
//+------------------------------------------------------------------+
class CMDXEngine
  {
private:
   MDXEngineConfig      m_cfg;
   CMDXPivotDetector    m_pivots;
   CMDXScorer           m_scorer;

   CMDXPivotSeries      m_highs;
   CMDXPivotSeries      m_lows;

   MDXSignalKey         m_mem[MDX_MAX_SIGNAL_MEMORY];
   int                  m_memHead;
   int                  m_memCount;

   //--- bar index up to which pivots have already been scanned
   int                  m_scannedTo;

public:
                     CMDXEngine(void){ ResetAll(); }

   void              SetPivotConfig(const MDXPivotConfig &c){ m_pivots.SetConfig(c); }
   void              SetScoreConfig(const MDXScoreConfig &c){ m_scorer.SetConfig(c); }
   void              SetEngineConfig(const MDXEngineConfig &c){ m_cfg=c; }

   MDXScoreConfig    ScoreConfig(void) const { return(m_scorer.Config()); }

   void              ResetAll(void)
     {
      m_highs.Clear();
      m_lows.Clear();
      m_memHead=0;
      m_memCount=0;
      m_scannedTo=-1;
      for(int i=0;i<MDX_MAX_SIGNAL_MEMORY;i++)
        { m_mem[i].t1=0; m_mem[i].t2=0; m_mem[i].type=MDX_DIV_NONE; }
     }

   int               ScannedTo(void) const { return(m_scannedTo); }
   void              SetScannedTo(const int v){ m_scannedTo=v; }

   const CMDXPivotSeries* Highs(void) const { return(GetPointer(m_highs)); }
   const CMDXPivotSeries* Lows(void)  const { return(GetPointer(m_lows)); }

   //--- duplicate suppression -------------------------------------
   bool              AlreadyFired(const datetime t1,const datetime t2,const int type) const
     {
      int n=MathMin(m_memCount,MDX_MAX_SIGNAL_MEMORY);
      for(int k=0;k<n;k++)
        {
         int idx=(m_memHead-1-k+2*MDX_MAX_SIGNAL_MEMORY)%MDX_MAX_SIGNAL_MEMORY;
         if(m_mem[idx].t1==t1 && m_mem[idx].t2==t2 && m_mem[idx].type==type)
            return(true);
        }
      return(false);
     }

   void              Remember(const datetime t1,const datetime t2,const int type)
     {
      m_mem[m_memHead].t1=t1;
      m_mem[m_memHead].t2=t2;
      m_mem[m_memHead].type=type;
      m_memHead=(m_memHead+1)%MDX_MAX_SIGNAL_MEMORY;
      m_memCount++;
     }

   //--- also suppress "same newer pivot, different older pivot" spam
   bool              FiredOnPivot(const datetime t2,const int type) const
     {
      int n=MathMin(m_memCount,MDX_MAX_SIGNAL_MEMORY);
      for(int k=0;k<n;k++)
        {
         int idx=(m_memHead-1-k+2*MDX_MAX_SIGNAL_MEMORY)%MDX_MAX_SIGNAL_MEMORY;
         if(m_mem[idx].t2==t2 && m_mem[idx].type==type) return(true);
        }
      return(false);
     }

   //+---------------------------------------------------------------+
   //| Snapshot oscillator values into a pivot record                 |
   //+---------------------------------------------------------------+
   void              FillOsc(MDXPivot &p,const CMDXOscillatorBank &bank,const int i) const
     {
      for(int o=0;o<MDX_MAX_OSC;o++)
        {
         p.osc[o]=0.0;
         p.oscValid[o]=false;
         if(!bank.Enabled(o) || !bank.Ready(o)) continue;
         double v=bank.Value(o,i);
         if(v==EMPTY_VALUE) continue;
         p.osc[o]=v;
         p.oscValid[o]=true;
        }
     }

   //+---------------------------------------------------------------+
   //| Scan bar 'i' for new pivots. Returns bitmask:                  |
   //|   1 = new/updated swing high, 2 = new/updated swing low        |
   //|                                                                |
   //| 'i' is the candidate pivot bar (non-series index).             |
   //+---------------------------------------------------------------+
   int               ScanPivotAt(const int i,const int total,
                                 const double &high[],const double &low[],
                                 const double &open[],const double &close[],
                                 const datetime &time[],
                                 const CMDXOscillatorBank &bank,
                                 const double atr,
                                 const bool allowTentative)
     {
      int res=0;
      MDXPivotConfig pc=m_pivots.Config();

      int rConf=MathMax(1,pc.rightBarsConf);
      int rTent=MathMax(1,MathMin(pc.rightBarsTent,rConf));

      //--- CONFIRMED detection ------------------------------------
      if(i+rConf<=total-1)
        {
         if(m_pivots.IsSwingHigh(high,open,close,i,total,rConf))
           {
            MDXPivot last;
            bool have=m_highs.Get(0,last);
            if(have && last.time==time[i])
              {
               //--- upgrade tentative -> confirmed
               if(!last.confirmed)
                 {
                  last.confirmed=true;
                  m_highs.UpdateLast(last);
                  res|=1;
                 }
              }
            else if(!have || last.time<time[i])
              {
               MDXPivot p; MDX_ResetPivot(p);
               p.bar=i; p.time=time[i];
               p.price=(pc.useWicks? high[i] : MathMax(open[i],close[i]));
               p.confirmed=true;
               FillOsc(p,bank,i);
               m_highs.Push(p);
               res|=1;
              }
           }

         if(m_pivots.IsSwingLow(low,open,close,i,total,rConf))
           {
            MDXPivot last;
            bool have=m_lows.Get(0,last);
            if(have && last.time==time[i])
              {
               if(!last.confirmed)
                 {
                  last.confirmed=true;
                  m_lows.UpdateLast(last);
                  res|=2;
                 }
              }
            else if(!have || last.time<time[i])
              {
               MDXPivot p; MDX_ResetPivot(p);
               p.bar=i; p.time=time[i];
               p.price=(pc.useWicks? low[i] : MathMin(open[i],close[i]));
               p.confirmed=true;
               FillOsc(p,bank,i);
               m_lows.Push(p);
               res|=2;
              }
           }
        }

      //--- TENTATIVE detection ------------------------------------
      if(allowTentative && rTent<rConf && i+rTent<=total-1 && i+rConf>total-1)
        {
         int ref=MathMin(total-1,i+rTent);

         if(m_pivots.IsSwingHigh(high,open,close,i,total,rTent))
           {
            double pv=(pc.useWicks? high[i] : MathMax(open[i],close[i]));
            double rp=(pc.useWicks? low[ref] : MathMin(open[ref],close[ref]));
            if(m_pivots.DisplacementOK(pv,rp,atr))
              {
               MDXPivot last;
               bool have=m_highs.Get(0,last);
               if(!have || last.time<time[i])
                 {
                  MDXPivot p; MDX_ResetPivot(p);
                  p.bar=i; p.time=time[i]; p.price=pv;
                  p.confirmed=false;
                  FillOsc(p,bank,i);
                  m_highs.Push(p);
                  res|=1;
                 }
               else if(have && last.time==time[i] && !last.confirmed)
                 {
                  last.price=pv;
                  FillOsc(last,bank,i);
                  m_highs.UpdateLast(last);
                  res|=1;
                 }
              }
           }

         if(m_pivots.IsSwingLow(low,open,close,i,total,rTent))
           {
            double pv=(pc.useWicks? low[i] : MathMin(open[i],close[i]));
            double rp=(pc.useWicks? high[ref] : MathMax(open[ref],close[ref]));
            if(m_pivots.DisplacementOK(pv,rp,atr))
              {
               MDXPivot last;
               bool have=m_lows.Get(0,last);
               if(!have || last.time<time[i])
                 {
                  MDXPivot p; MDX_ResetPivot(p);
                  p.bar=i; p.time=time[i]; p.price=pv;
                  p.confirmed=false;
                  FillOsc(p,bank,i);
                  m_lows.Push(p);
                  res|=2;
                 }
               else if(have && last.time==time[i] && !last.confirmed)
                 {
                  last.price=pv;
                  FillOsc(last,bank,i);
                  m_lows.UpdateLast(last);
                  res|=2;
                 }
              }
           }
        }

      return(res);
     }

   //--- discard tentative pivots that price has invalidated
   void              PruneTentative(const int i,const double &high[],const double &low[],
                                    const double &open[],const double &close[])
     {
      MDXPivotConfig pc=m_pivots.Config();
      MDXPivot p;

      if(m_highs.Get(0,p) && !p.confirmed && p.bar<i)
        {
         double v=(pc.useWicks? high[i] : MathMax(open[i],close[i]));
         if(v>p.price) m_highs.DropFrom(p.bar);
        }
      if(m_lows.Get(0,p) && !p.confirmed && p.bar<i)
        {
         double v=(pc.useWicks? low[i] : MathMin(open[i],close[i]));
         if(v<p.price) m_lows.DropFrom(p.bar);
        }
     }

   //+---------------------------------------------------------------+
   //| Evaluate divergence on the newest LOW pivot (bullish family)   |
   //+---------------------------------------------------------------+
   bool              EvaluateBullish(const CMDXOscillatorBank &bank,
                                     const double atr,
                                     const int trendBias,
                                     const bool volOK,
                                     MDXResult &best)
     {
      MDX_ResetResult(best);
      MDXPivot p2;
      if(!m_lows.Get(0,p2)) return(false);

      int maxBack=MathMin(m_cfg.maxPivotLookback,m_lows.Count()-1);
      if(maxBack<1) return(false);

      bool wantReg=(m_cfg.divMode==MDX_MODE_REGULAR_ONLY || m_cfg.divMode==MDX_MODE_BOTH);
      bool wantHid=(m_cfg.divMode==MDX_MODE_HIDDEN_ONLY  || m_cfg.divMode==MDX_MODE_BOTH);

      int pairs=(m_cfg.allowMultiPair? maxBack : 1);

      for(int b=1;b<=pairs;b++)
        {
         MDXPivot p1;
         if(!m_lows.Get(b,p1)) break;

         int gap=p2.bar-p1.bar;
         if(gap<m_cfg.minBarGap) continue;
         if(gap>m_cfg.maxBarGap) break;

         double pd=MathAbs(p2.price-p1.price);
         if(atr>0.0 && m_cfg.minPriceDeltaAtr>0.0 && pd<atr*m_cfg.minPriceDeltaAtr)
            continue;

         //--- REGULAR BULLISH: price lower low, oscillators higher low
         if(wantReg && p2.price<p1.price)
           {
            double sc; int ag,cf,mk;
            if(m_scorer.Evaluate(bank,p1,p2,true,atr,sc,ag,cf,mk))
              {
               double pq=m_scorer.PriceQuality(p1.price,p2.price,atr);
               bool tent=(!p1.confirmed || !p2.confirmed);
               bool trendBad=(m_cfg.trendMode!=MDX_TRENDMODE_BLOCK? (trendBias<0) : (trendBias<0));
               double fs=m_scorer.Finalize(sc,pq,tent,false,trendBad,!volOK,
                                           gap,m_cfg.idealMinGap,m_cfg.idealMaxGap);
               if(fs>best.score)
                 {
                  best.type=MDX_DIV_REG_BULL; best.score=fs;
                  best.agree=ag; best.conflict=cf; best.mask=mk;
                  best.barIndex=p2.bar; best.barTime=p2.time; best.price=p2.price;
                  best.tentative=tent;
                 }
              }
           }

         //--- HIDDEN BULLISH: price higher low, oscillators lower low
         if(wantHid && p2.price>p1.price)
           {
            double sc; int ag,cf,mk;
            if(m_scorer.Evaluate(bank,p1,p2,false,atr,sc,ag,cf,mk))
              {
               double pq=m_scorer.PriceQuality(p1.price,p2.price,atr);
               bool tent=(!p1.confirmed || !p2.confirmed);
               bool trendBad=(trendBias<0);
               double fs=m_scorer.Finalize(sc,pq,tent,true,trendBad,!volOK,
                                           gap,m_cfg.idealMinGap,m_cfg.idealMaxGap);
               if(fs>best.score)
                 {
                  best.type=MDX_DIV_HID_BULL; best.score=fs;
                  best.agree=ag; best.conflict=cf; best.mask=mk;
                  best.barIndex=p2.bar; best.barTime=p2.time; best.price=p2.price;
                  best.tentative=tent;
                 }
              }
           }
        }

      return(best.type!=MDX_DIV_NONE);
     }

   //+---------------------------------------------------------------+
   //| Evaluate divergence on the newest HIGH pivot (bearish family)  |
   //+---------------------------------------------------------------+
   bool              EvaluateBearish(const CMDXOscillatorBank &bank,
                                     const double atr,
                                     const int trendBias,
                                     const bool volOK,
                                     MDXResult &best)
     {
      MDX_ResetResult(best);
      MDXPivot p2;
      if(!m_highs.Get(0,p2)) return(false);

      int maxBack=MathMin(m_cfg.maxPivotLookback,m_highs.Count()-1);
      if(maxBack<1) return(false);

      bool wantReg=(m_cfg.divMode==MDX_MODE_REGULAR_ONLY || m_cfg.divMode==MDX_MODE_BOTH);
      bool wantHid=(m_cfg.divMode==MDX_MODE_HIDDEN_ONLY  || m_cfg.divMode==MDX_MODE_BOTH);

      int pairs=(m_cfg.allowMultiPair? maxBack : 1);

      for(int b=1;b<=pairs;b++)
        {
         MDXPivot p1;
         if(!m_highs.Get(b,p1)) break;

         int gap=p2.bar-p1.bar;
         if(gap<m_cfg.minBarGap) continue;
         if(gap>m_cfg.maxBarGap) break;

         double pd=MathAbs(p2.price-p1.price);
         if(atr>0.0 && m_cfg.minPriceDeltaAtr>0.0 && pd<atr*m_cfg.minPriceDeltaAtr)
            continue;

         //--- REGULAR BEARISH: price higher high, oscillators lower high
         if(wantReg && p2.price>p1.price)
           {
            double sc; int ag,cf,mk;
            if(m_scorer.Evaluate(bank,p1,p2,false,atr,sc,ag,cf,mk))
              {
               double pq=m_scorer.PriceQuality(p1.price,p2.price,atr);
               bool tent=(!p1.confirmed || !p2.confirmed);
               bool trendBad=(trendBias>0);
               double fs=m_scorer.Finalize(sc,pq,tent,false,trendBad,!volOK,
                                           gap,m_cfg.idealMinGap,m_cfg.idealMaxGap);
               if(fs>best.score)
                 {
                  best.type=MDX_DIV_REG_BEAR; best.score=fs;
                  best.agree=ag; best.conflict=cf; best.mask=mk;
                  best.barIndex=p2.bar; best.barTime=p2.time; best.price=p2.price;
                  best.tentative=tent;
                 }
              }
           }

         //--- HIDDEN BEARISH: price lower high, oscillators higher high
         if(wantHid && p2.price<p1.price)
           {
            double sc; int ag,cf,mk;
            if(m_scorer.Evaluate(bank,p1,p2,true,atr,sc,ag,cf,mk))
              {
               double pq=m_scorer.PriceQuality(p1.price,p2.price,atr);
               bool tent=(!p1.confirmed || !p2.confirmed);
               bool trendBad=(trendBias>0);
               double fs=m_scorer.Finalize(sc,pq,tent,true,trendBad,!volOK,
                                           gap,m_cfg.idealMinGap,m_cfg.idealMaxGap);
               if(fs>best.score)
                 {
                  best.type=MDX_DIV_HID_BEAR; best.score=fs;
                  best.agree=ag; best.conflict=cf; best.mask=mk;
                  best.barIndex=p2.bar; best.barTime=p2.time; best.price=p2.price;
                  best.tentative=tent;
                 }
              }
           }
        }

      return(best.type!=MDX_DIV_NONE);
     }

   bool              Passes(const MDXResult &r) const
     {
      return(m_scorer.PassesThreshold(r.score,r.agree));
     }
  };


//==================================================================
//  SECTION 7 : MDX_Render  (chart objects + dashboard)
//==================================================================
#define MDX_OBJ_PREFIX "MDX_"

//+------------------------------------------------------------------+
class CMDXRender
  {
private:
   long              m_chart;
   int               m_window;
   string            m_prefix;
   bool              m_drawLines;
   bool              m_drawLabels;
   color             m_bullColor;
   color             m_bearColor;
   color             m_hidBullColor;
   color             m_hidBearColor;
   int               m_lineWidth;
   ENUM_LINE_STYLE   m_lineStyle;
   int               m_fontSize;
   string            m_font;
   int               m_maxObjects;
   int               m_objCounter;

public:
                     CMDXRender(void)
     {
      m_chart=0; m_window=0; m_prefix=MDX_OBJ_PREFIX;
      m_drawLines=true; m_drawLabels=true;
      m_bullColor=clrDodgerBlue; m_bearColor=clrOrangeRed;
      m_hidBullColor=clrMediumSeaGreen; m_hidBearColor=clrMediumVioletRed;
      m_lineWidth=1; m_lineStyle=STYLE_SOLID;
      m_fontSize=8; m_font="Arial";
      m_maxObjects=400; m_objCounter=0;
     }

   void              Init(const long chart,const int window,const string prefix,
                          const bool drawLines,const bool drawLabels,
                          const color bull,const color bear,
                          const color hbull,const color hbear,
                          const int width,const ENUM_LINE_STYLE style,
                          const int fontSize,const string font,
                          const int maxObjects)
     {
      m_chart=chart; m_window=window; m_prefix=prefix;
      m_drawLines=drawLines; m_drawLabels=drawLabels;
      m_bullColor=bull; m_bearColor=bear;
      m_hidBullColor=hbull; m_hidBearColor=hbear;
      m_lineWidth=MathMax(1,width); m_lineStyle=style;
      m_fontSize=MathMax(6,fontSize); m_font=font;
      m_maxObjects=MathMax(50,maxObjects);
     }

   color             ColorFor(const ENUM_MDX_DIVTYPE t) const
     {
      switch(t)
        {
         case MDX_DIV_REG_BULL: return(m_bullColor);
         case MDX_DIV_REG_BEAR: return(m_bearColor);
         case MDX_DIV_HID_BULL: return(m_hidBullColor);
         case MDX_DIV_HID_BEAR: return(m_hidBearColor);
        }
      return(clrGray);
     }

   void              CleanAll(void)
     {
      ObjectsDeleteAll(m_chart,m_prefix,-1,-1);
      m_objCounter=0;
      ChartRedraw(m_chart);
     }

   //--- keep object count bounded on busy 1-minute charts
   void              Housekeep(void)
     {
      int total=ObjectsTotal(m_chart,-1,-1);
      if(total<=m_maxObjects) return;
      //--- delete oldest MDX objects (name encodes creation counter)
      int toDelete=total-m_maxObjects;
      for(int i=0;i<ObjectsTotal(m_chart,-1,-1) && toDelete>0;)
        {
         string nm=ObjectName(m_chart,i,-1,-1);
         if(StringFind(nm,m_prefix)==0 && StringFind(nm,"DASH")<0 && StringFind(nm,"DP_")<0)
           {
            ObjectDelete(m_chart,nm);
            toDelete--;
           }
         else i++;
        }
     }

   //--- connector line between the two pivots forming the divergence
   void              DrawLink(const datetime t1,const double p1,
                              const datetime t2,const double p2,
                              const ENUM_MDX_DIVTYPE type,
                              const double score,const bool tentative)
     {
      if(!m_drawLines) return;
      m_objCounter++;
      string nm=StringFormat("%sLNK_%d_%I64d",m_prefix,m_objCounter,(long)t2);
      if(!ObjectCreate(m_chart,nm,OBJ_TREND,m_window,t1,p1,t2,p2)) return;
      ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,ColorFor(type));
      ObjectSetInteger(m_chart,nm,OBJPROP_WIDTH,m_lineWidth);
      ObjectSetInteger(m_chart,nm,OBJPROP_STYLE,tentative? STYLE_DOT : m_lineStyle);
      ObjectSetInteger(m_chart,nm,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(m_chart,nm,OBJPROP_RAY_LEFT,false);
      ObjectSetInteger(m_chart,nm,OBJPROP_BACK,true);
      ObjectSetInteger(m_chart,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chart,nm,OBJPROP_HIDDEN,true);
      ObjectSetString(m_chart,nm,OBJPROP_TOOLTIP,
                      StringFormat("%s | score %.0f%s",MDX_DivName(type),score,
                                   tentative? " (early)" : ""));
     }

   //--- small score label next to the signal
   void              DrawScoreLabel(const datetime t,const double price,
                                    const ENUM_MDX_DIVTYPE type,
                                    const double score,const string oscList,
                                    const bool below)
     {
      if(!m_drawLabels) return;
      m_objCounter++;
      string nm=StringFormat("%sLBL_%d_%I64d",m_prefix,m_objCounter,(long)t);
      if(!ObjectCreate(m_chart,nm,OBJ_TEXT,m_window,t,price)) return;
      ObjectSetString(m_chart,nm,OBJPROP_TEXT,
                      StringFormat("%.0f %s",score,oscList));
      ObjectSetString(m_chart,nm,OBJPROP_FONT,m_font);
      ObjectSetInteger(m_chart,nm,OBJPROP_FONTSIZE,m_fontSize);
      ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,ColorFor(type));
      ObjectSetInteger(m_chart,nm,OBJPROP_ANCHOR,below? ANCHOR_UPPER : ANCHOR_LOWER);
      ObjectSetInteger(m_chart,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chart,nm,OBJPROP_HIDDEN,true);
     }

   //--- (legacy text dashboard removed - replaced by CMDXDashPanel) -
  };


//==================================================================
//  SECTION 8 : MDX_Alerts  (alert dispatcher)
//==================================================================
//+------------------------------------------------------------------+
class CMDXAlerts
  {
private:
   bool              m_popup;
   bool              m_sound;
   bool              m_push;
   bool              m_email;
   string            m_soundBull;
   string            m_soundBear;
   ENUM_MDX_ALERTMODE m_mode;
   bool              m_alertOnTentative;
   datetime          m_lastBullBar;
   datetime          m_lastBearBar;
   string            m_symbol;
   string            m_tfName;
   int               m_cooldownSec;
   datetime          m_lastAnySent;

public:
                     CMDXAlerts(void)
     {
      m_popup=true; m_sound=false; m_push=false; m_email=false;
      m_soundBull="alert.wav"; m_soundBear="alert2.wav";
      m_mode=MDX_ALERT_ONCE_PER_BAR;
      m_alertOnTentative=false;
      m_lastBullBar=0; m_lastBearBar=0; m_lastAnySent=0;
      m_symbol=_Symbol; m_tfName="M1"; m_cooldownSec=0;
     }

   void              Init(const bool popup,const bool sound,const bool push,const bool email,
                          const string sndBull,const string sndBear,
                          const ENUM_MDX_ALERTMODE mode,const bool onTentative,
                          const string symbol,const ENUM_TIMEFRAMES tf,
                          const int cooldownSec)
     {
      m_popup=popup; m_sound=sound; m_push=push; m_email=email;
      m_soundBull=sndBull; m_soundBear=sndBear;
      m_mode=mode; m_alertOnTentative=onTentative;
      m_symbol=symbol;
      m_tfName=EnumToString(tf);
      StringReplace(m_tfName,"PERIOD_","");
      m_cooldownSec=MathMax(0,cooldownSec);
     }

   void              Reset(void){ m_lastBullBar=0; m_lastBearBar=0; m_lastAnySent=0; }

   bool              Fire(const MDXResult &r,const datetime barTime,
                          const double price,const string oscList,
                          const int trendBias,const bool isRealtime)
     {
      if(!isRealtime) return(false);                 // never alert on history
      if(r.tentative && !m_alertOnTentative) return(false);

      bool bull=MDX_IsBull(r.type);

      if(m_mode==MDX_ALERT_ONCE_PER_BAR)
        {
         if(bull && m_lastBullBar==barTime) return(false);
         if(!bull && m_lastBearBar==barTime) return(false);
        }

      if(m_cooldownSec>0 && m_lastAnySent>0)
        {
         if((TimeCurrent()-m_lastAnySent)<m_cooldownSec) return(false);
        }

      if(bull) m_lastBullBar=barTime; else m_lastBearBar=barTime;
      m_lastAnySent=TimeCurrent();

      string trendTxt=(trendBias>0? "UP" : (trendBias<0? "DOWN" : "FLAT"));
      string msg=StringFormat("%s %s | %s | conf %.0f%% | agree %d/%d [%s] | trend %s | @ %s%s",
                              m_symbol,m_tfName,MDX_DivName(r.type),r.score,
                              r.agree,r.agree+r.conflict,oscList,trendTxt,
                              DoubleToString(price,_Digits),
                              r.tentative? " (EARLY)" : "");

      if(m_popup) Alert(msg);
      if(m_sound) PlaySound(bull? m_soundBull : m_soundBear);
      if(m_push)  SendNotification(msg);
      if(m_email) SendMail(StringFormat("MDX Divergence %s %s",m_symbol,m_tfName),msg);

      return(true);
     }
  };


//==================================================================
//  SECTION 9 : MAIN INDICATOR  (inputs, buffers, lifecycle, calc)
//==================================================================

//+------------------------------------------------------------------+
//|                          INPUTS                                   |
//+------------------------------------------------------------------+
input group "=== 1. Core / Sensitivity ==="
input ENUM_MDX_SENSITIVITY InpSensitivity      = MDX_SENS_MEDIUM;   // Sensitivity preset
input ENUM_MDX_DIVMODE     InpDivMode          = MDX_MODE_REGULAR_ONLY; // Divergence families
input ENUM_MDX_PIVOTPOLICY InpPivotPolicy      = MDX_PIVOT_HYBRID;  // Pivot confirmation policy
input int                  InpMaxBarsToScan    = 3000;              // Max bars to process (0 = all)

input group "=== 2. Pivot / Swing Detection (CUSTOM preset only) ==="
input int                  InpLeftBars         = 3;                 // Left bars
input int                  InpRightBarsConf    = 3;                 // Right bars (confirmed)
input int                  InpRightBarsTent    = 1;                 // Right bars (tentative/early)
input bool                 InpUseWicks         = true;              // Use wicks (high/low) not bodies
input bool                 InpStrictLeft       = true;              // Strict comparison on left side
input double               InpMinAtrDisplace   = 0.15;              // Min ATR displacement for early pivot

input group "=== 3. Pairing Geometry ==="
input int                  InpMaxPivotLookback = 4;                 // How many previous pivots to test
input bool                 InpAllowMultiPair   = true;              // Test several pivots, keep best
input int                  InpMinBarGap        = 4;                 // Min bars between pivots
input int                  InpMaxBarGap        = 90;                // Max bars between pivots
input int                  InpIdealMinGap      = 6;                 // Ideal min gap (no penalty above)
input int                  InpIdealMaxGap      = 60;                // Ideal max gap (no penalty below)
input double               InpMinPriceDeltaATR = 0.10;              // Min price separation (x ATR)

input group "=== 4. Oscillator Modules ==="
input bool                 InpUseRSI           = true;              // Enable RSI module
input int                  InpRSIPeriod        = 9;                 // RSI period
input ENUM_APPLIED_PRICE   InpRSIPrice         = PRICE_CLOSE;       // RSI price
input double               InpWeightRSI        = 1.20;              // RSI weight

input bool                 InpUseCCI           = true;              // Enable CCI module
input int                  InpCCIPeriod        = 14;                // CCI period
input ENUM_APPLIED_PRICE   InpCCIPrice         = PRICE_TYPICAL;     // CCI price
input double               InpWeightCCI        = 1.00;              // CCI weight

input bool                 InpUseMOM           = true;              // Enable Momentum module
input int                  InpMOMPeriod        = 10;                // Momentum period
input ENUM_APPLIED_PRICE   InpMOMPrice         = PRICE_CLOSE;       // Momentum price
input double               InpWeightMOM        = 0.80;              // Momentum weight

input bool                 InpUseSTO           = true;              // Enable Stochastic module
input int                  InpSTOK             = 8;                 // Stochastic %K
input int                  InpSTOD             = 3;                 // Stochastic %D
input int                  InpSTOSlow          = 3;                 // Stochastic slowing
input ENUM_STO_PRICE       InpSTOField         = STO_LOWHIGH;       // Stochastic price field
input double               InpWeightSTO        = 0.90;              // Stochastic weight

input bool                 InpUseMACD          = true;              // Enable MACD module
input int                  InpMACDFast         = 8;                 // MACD fast EMA
input int                  InpMACDSlow         = 17;                // MACD slow EMA
input int                  InpMACDSignal       = 6;                 // MACD signal
input ENUM_APPLIED_PRICE   InpMACDPrice        = PRICE_CLOSE;       // MACD price
input bool                 InpMACDHistogram    = true;              // Use MACD histogram (faster)
input double               InpWeightMACD       = 1.10;              // MACD weight

input group "=== 5. Scoring ==="
input double               InpMinScore         = 55.0;              // Min composite score (0-100)
input int                  InpMinAgree         = 2;                 // Min agreeing oscillators
input double               InpConflictPenalty  = 0.85;              // Conflict vote multiplier
input double               InpNoiseBandPct     = 8.0;               // Neutral band (% of full delta)
input double               InpTentativePenalty = 0.85;              // Early-signal score multiplier
input double               InpHiddenPenalty    = 0.90;              // Hidden divergence multiplier
input double               InpTrendPenalty     = 0.70;              // Counter-trend multiplier
input double               InpVolPenalty       = 0.80;              // Bad-volatility multiplier
input double               InpPriceQualityW    = 0.35;              // Price-leg quality weight (0-1)

input group "=== 6. Trend Filter ==="
input ENUM_MDX_TRENDFILTER InpTrendFilter      = MDX_TREND_EMA;     // Trend filter type
input ENUM_MDX_TRENDMODE   InpTrendMode        = MDX_TRENDMODE_PENALIZE; // Block or penalize
input int                  InpTrendFastEMA     = 21;                // Fast EMA period
input int                  InpTrendSlowEMA     = 55;                // Slow EMA period
input int                  InpTrendSlopeBars   = 3;                 // Slope measurement bars
input ENUM_APPLIED_PRICE   InpTrendPrice       = PRICE_CLOSE;       // Trend EMA price

input group "=== 7. Volatility Filter (ATR) ==="
input bool                 InpUseVolFilter     = true;              // Enable ATR regime filter
input int                  InpATRPeriod        = 14;                // ATR period
input int                  InpATRAvgLen        = 50;                // ATR average length
input double               InpATRMinMult       = 0.55;              // Min ATR / avgATR
input double               InpATRMaxMult       = 0.00;              // Max ATR / avgATR (0 = off)

input group "=== 8. Session Filter (server time) ==="
input bool                 InpUseSession       = false;             // Enable session filter
input string               InpSess1From        = "07:00";           // Session 1 from
input string               InpSess1To          = "11:00";           // Session 1 to
input string               InpSess2From        = "12:30";           // Session 2 from
input string               InpSess2To          = "17:00";           // Session 2 to
input string               InpSess3From        = "00:00";           // Session 3 from
input string               InpSess3To          = "00:00";           // Session 3 to
input bool                 InpSkipFridayLate   = true;              // Skip late Friday
input string               InpFridayCutoff     = "19:00";           // Friday cutoff
input bool                 InpSkipMondayEarly  = false;             // Skip early Monday
input string               InpMondayOpen       = "01:00";           // Monday open

input group "=== 9. Display ==="
input bool                 InpShowArrows       = true;              // Show arrows
input int                  InpArrowBull        = 233;               // Bullish arrow code
input int                  InpArrowBear        = 234;               // Bearish arrow code
input int                  InpArrowHidBull     = 225;               // Hidden bull arrow code
input int                  InpArrowHidBear     = 226;               // Hidden bear arrow code
input double               InpArrowOffsetATR   = 0.60;              // Arrow offset (x ATR)
input bool                 InpDrawLines        = true;              // Draw divergence lines
input bool                 InpDrawScoreLabels  = true;              // Draw score labels
input int                  InpLabelFontSize    = 8;                 // Label font size
input string               InpLabelFont        = "Arial";           // Label font
input int                  InpMaxChartObjects  = 400;               // Max chart objects
input bool                 InpShowDashboard    = true;              // Show dashboard
input int                  InpDashCorner       = 0;                 // Dashboard corner (0-3)
input int                  InpDashX            = 12;                // Dashboard X
input int                  InpDashY            = 18;                // Dashboard Y
input color                InpDashColor        = clrSilver;         // Dashboard text color
input int                  InpDashFontSize     = 9;                 // Dashboard font size

input group "=== 10. Alerts ==="
input bool                 InpAlertPopup       = true;              // Popup alert
input bool                 InpAlertSound       = false;             // Sound alert
input bool                 InpAlertPush        = false;             // Push notification
input bool                 InpAlertEmail       = false;             // Email alert
input string               InpSoundBull        = "alert.wav";       // Bullish sound
input string               InpSoundBear        = "alert2.wav";      // Bearish sound
input ENUM_MDX_ALERTMODE   InpAlertMode        = MDX_ALERT_ONCE_PER_BAR; // Alert throttle
input bool                 InpAlertOnEarly     = false;             // Alert on early (tentative) signals
input int                  InpAlertCooldownSec = 20;                // Global cooldown (seconds)

//+------------------------------------------------------------------+
//|  Runtime-editable working copies of the two setting groups        |
//|  exposed on the chart dashboard (CMDXDashPanel).  Initialised     |
//|  from the matching input parameters in OnInit() and then mutated  |
//|  only by the dashboard.  All engine / filter logic reads these    |
//|  instead of the (read-only) inputs so settings can change live.   |
//+------------------------------------------------------------------+
ENUM_MDX_SENSITIVITY g_Sensitivity;
ENUM_MDX_DIVMODE     g_DivMode;
ENUM_MDX_PIVOTPOLICY g_PivotPolicy;
int                  g_MaxBarsToScan;
ENUM_MDX_TRENDFILTER g_TrendFilter;
ENUM_MDX_TRENDMODE   g_TrendMode;
int                  g_TrendFastEMA;
int                  g_TrendSlowEMA;
int                  g_TrendSlopeBars;
ENUM_APPLIED_PRICE   g_TrendPrice;

bool                 g_forceRebuild = false;   // dashboard sets this after a live edit

//+------------------------------------------------------------------+
//|                        BUFFERS                                    |
//+------------------------------------------------------------------+
double BufBull[];          // 0 - regular bullish arrow price
double BufBear[];          // 1 - regular bearish arrow price
double BufHidBull[];       // 2 - hidden bullish arrow price
double BufHidBear[];       // 3 - hidden bearish arrow price
double BufScore[];         // 4 - signed confidence (+bull / -bear), 0 = none
double BufAgree[];         // 5 - agreeing oscillator count
double BufMask[];          // 6 - bitmask of agreeing oscillators
double BufTrend[];         // 7 - trend bias (+1/0/-1)

//+------------------------------------------------------------------+
//|                       GLOBAL OBJECTS                              |
//+------------------------------------------------------------------+
CMDXOscillatorBank g_bank;
CMDXEngine         g_engine;
CMDXTrendFilter    g_trend;
CMDXVolFilter      g_vol;
CMDXSessionFilter  g_session;
CMDXRender         g_render;
CMDXAlerts         g_alerts;

int      g_warmup        = 100;
int      g_lastCalc      = 0;
datetime g_lastBarTime   = 0;
bool     g_initOK        = false;
int      g_effLeft       = 3;
int      g_effRightConf  = 3;
int      g_effRightTent  = 1;
double   g_effMinScore   = 55.0;
int      g_effMinAgree   = 2;
double   g_effMinAtrDisp = 0.15;

//--- last emitted signal (for dashboard)
MDXResult g_lastSignal;
datetime  g_lastSignalTime = 0;

//+------------------------------------------------------------------+
//| Build the human-readable list of agreeing oscillators             |
//+------------------------------------------------------------------+
string MaskToText(const int mask)
  {
   string s="";
   for(int o=0;o<MDX_MAX_OSC;o++)
     {
      if((mask&(1<<o))!=0)
        {
         if(StringLen(s)>0) s+="+";
         s+=MDX_OscName(o);
        }
     }
   if(StringLen(s)==0) s="-";
   return(s);
  }

//+------------------------------------------------------------------+
//| Apply the sensitivity preset to the effective parameters          |
//+------------------------------------------------------------------+
void ApplySensitivityPreset(void)
  {
   switch(g_Sensitivity)
     {
      case MDX_SENS_FAST:
         g_effLeft       = 2;
         g_effRightConf  = 2;
         g_effRightTent  = 1;
         g_effMinScore   = MathMax(35.0,InpMinScore-15.0);
         g_effMinAgree   = MathMax(1,InpMinAgree-1);
         g_effMinAtrDisp = 0.08;
         break;

      case MDX_SENS_MEDIUM:
         g_effLeft       = 3;
         g_effRightConf  = 3;
         g_effRightTent  = 1;
         g_effMinScore   = InpMinScore;
         g_effMinAgree   = InpMinAgree;
         g_effMinAtrDisp = 0.15;
         break;

      case MDX_SENS_CONSERVATIVE:
         g_effLeft       = 5;
         g_effRightConf  = 5;
         g_effRightTent  = 3;
         g_effMinScore   = MathMin(95.0,InpMinScore+12.0);
         g_effMinAgree   = MathMin(MDX_MAX_OSC,InpMinAgree+1);
         g_effMinAtrDisp = 0.25;
         break;

      case MDX_SENS_CUSTOM:
      default:
         g_effLeft       = MathMax(1,InpLeftBars);
         g_effRightConf  = MathMax(1,InpRightBarsConf);
         g_effRightTent  = MathMax(1,MathMin(InpRightBarsTent,InpRightBarsConf));
         g_effMinScore   = InpMinScore;
         g_effMinAgree   = InpMinAgree;
         g_effMinAtrDisp = InpMinAtrDisplace;
         break;
     }

   //--- pivot policy overrides the tentative depth
   if(g_PivotPolicy==MDX_PIVOT_CONFIRMED)
      g_effRightTent=g_effRightConf;                 // disables early detection
   else if(g_PivotPolicy==MDX_PIVOT_TENTATIVE)
      g_effRightConf=MathMax(g_effRightTent,1);      // everything is "early"
  }

//+------------------------------------------------------------------+
//| Re-apply the Core/Sensitivity + Trend Filter settings to the      |
//| engine and trend filter.  Called by the dashboard after a live    |
//| edit so the new values take effect on the next recalculation.     |
//+------------------------------------------------------------------+
void ApplyCoreSettings(void)
  {
   ApplySensitivityPreset();

   MDXPivotConfig pc;
   pc.leftBars          = g_effLeft;
   pc.rightBarsConf     = g_effRightConf;
   pc.rightBarsTent     = g_effRightTent;
   pc.policy            = g_PivotPolicy;
   pc.useWicks          = InpUseWicks;
   pc.minAtrDisplace    = g_effMinAtrDisp;
   pc.requireStrictLeft = InpStrictLeft;
   g_engine.SetPivotConfig(pc);

   MDXScoreConfig sc;
   sc.weight[MDX_OSC_RSI]   = MathMax(0.0,InpWeightRSI);
   sc.weight[MDX_OSC_CCI]   = MathMax(0.0,InpWeightCCI);
   sc.weight[MDX_OSC_MOM]   = MathMax(0.0,InpWeightMOM);
   sc.weight[MDX_OSC_STOCH] = MathMax(0.0,InpWeightSTO);
   sc.weight[MDX_OSC_MACD]  = MathMax(0.0,InpWeightMACD);
   sc.conflictPenalty   = MathMax(0.0,InpConflictPenalty);
   sc.minScore          = MDX_Clamp(g_effMinScore,0.0,100.0);
   sc.minAgree          = MathMax(1,g_effMinAgree);
   sc.noiseBandPct      = MathMax(0.0,InpNoiseBandPct);
   sc.tentativePenalty  = InpTentativePenalty;
   sc.hiddenPenalty     = InpHiddenPenalty;
   sc.trendPenalty      = InpTrendPenalty;
   sc.volPenalty        = InpVolPenalty;
   sc.priceQualityWeight= MDX_Clamp(InpPriceQualityW,0.0,1.0);
   sc.slopeQualityWeight= 0.5;
   g_engine.SetScoreConfig(sc);

   MDXEngineConfig ec;
   ec.divMode           = g_DivMode;
   ec.maxPivotLookback  = MathMax(1,InpMaxPivotLookback);
   ec.minBarGap         = MathMax(1,InpMinBarGap);
   ec.maxBarGap         = MathMax(ec.minBarGap+1,InpMaxBarGap);
   ec.idealMinGap       = MathMax(1,InpIdealMinGap);
   ec.idealMaxGap       = MathMax(ec.idealMinGap+1,InpIdealMaxGap);
   ec.allowMultiPair    = InpAllowMultiPair;
   ec.requireCloseBreak = false;
   ec.minPriceDeltaAtr  = MathMax(0.0,InpMinPriceDeltaATR);
   ec.trendMode         = g_TrendMode;
   g_engine.SetEngineConfig(ec);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("MDX Divergence [%s|%s]",
                                   EnumToString(g_Sensitivity),
                                   EnumToString(g_DivMode)));

   g_warmup=MathMax(g_bank.WarmupBars(),
            MathMax(g_trend.WarmupBars(),g_vol.WarmupBars()));
   g_warmup=MathMax(g_warmup,g_effLeft+g_effRightConf+5)+10;
   g_lastCalc=0;
   g_forceRebuild=true;
  }

//+------------------------------------------------------------------+
//| Re-init the trend filter with the current dashboard values        |
//+------------------------------------------------------------------+
void ApplyTrendSettings(void)
  {
   if(!g_trend.Init(_Symbol,PERIOD_CURRENT,g_TrendFilter,
                    g_TrendFastEMA,g_TrendSlowEMA,g_TrendSlopeBars,g_TrendPrice))
      Print("MDX: trend filter re-init failed");

   g_warmup=MathMax(g_bank.WarmupBars(),
            MathMax(g_trend.WarmupBars(),g_vol.WarmupBars()));
   g_warmup=MathMax(g_warmup,g_effLeft+g_effRightConf+5)+10;
   g_lastCalc=0;
   g_forceRebuild=true;
  }

//==================================================================
//  SECTION 7b : MDX_DashPanel
//  Collapsible on-chart settings dashboard.
//    * one master button collapses / expands the whole panel
//    * two "drawer" sections (Core/Sensitivity, Trend Filter)
//    * each setting row = label + prev + value + next
//  Enum settings cycle through their values, integer settings step.
//  Only the two exposed setting groups are shown - nothing else.
//==================================================================
class CMDXDashPanel
  {
private:
   long    m_chart;
   string  m_prefix;
   int     m_corner;
   int     m_x;
   int     m_y;
   int     m_fontSize;
   string  m_font;
   color   m_textColor;
   color   m_bgColor;
   color   m_headerColor;
   color   m_btnColor;
   color   m_btnTextColor;
   color   m_valColor;
   int     m_panelW;
   bool    m_collapsed;
   bool    m_coreOpen;
   bool    m_trendOpen;

   int     RowH(void)  const { return(m_fontSize+10); }
   int     BtnH(void)  const { return(m_fontSize+8); }
   int     Pad(void)   const { return(8); }
   int     NameW(void) const { return(116); }
   int     StepW(void) const { return(20); }
   int     ValW(void)  const { return(80); }

   string  SensName(const ENUM_MDX_SENSITIVITY v) const
     {
      switch(v)
        {
         case MDX_SENS_FAST:         return("FAST");
         case MDX_SENS_MEDIUM:       return("MEDIUM");
         case MDX_SENS_CONSERVATIVE: return("CONSERV");
         case MDX_SENS_CUSTOM:       return("CUSTOM");
        }
      return("?");
     }
   string  DivName(const ENUM_MDX_DIVMODE v) const
     {
      switch(v)
        {
         case MDX_MODE_REGULAR_ONLY: return("REG ONLY");
         case MDX_MODE_HIDDEN_ONLY:  return("HID ONLY");
         case MDX_MODE_BOTH:         return("BOTH");
        }
      return("?");
     }
   string  PivotName(const ENUM_MDX_PIVOTPOLICY v) const
     {
      switch(v)
        {
         case MDX_PIVOT_CONFIRMED: return("CONFIRMED");
         case MDX_PIVOT_TENTATIVE: return("EARLY");
         case MDX_PIVOT_HYBRID:    return("HYBRID");
        }
      return("?");
     }
   string  TrendFName(const ENUM_MDX_TRENDFILTER v) const
     {
      switch(v)
        {
         case MDX_TREND_OFF:       return("OFF");
         case MDX_TREND_EMA:       return("EMA");
         case MDX_TREND_EMA_CROSS: return("CROSS");
         case MDX_TREND_STRUCTURE: return("STRUCT");
        }
      return("?");
     }
   string  TrendMName(const ENUM_MDX_TRENDMODE v) const
     {
      switch(v)
        {
         case MDX_TRENDMODE_BLOCK:    return("BLOCK");
         case MDX_TRENDMODE_PENALIZE: return("PENAL");
        }
      return("?");
     }
   string  PriceName(const ENUM_APPLIED_PRICE v) const
     {
      switch(v)
        {
         case PRICE_CLOSE:    return("CLOSE");
         case PRICE_OPEN:     return("OPEN");
         case PRICE_HIGH:     return("HIGH");
         case PRICE_LOW:      return("LOW");
         case PRICE_MEDIAN:   return("MEDIAN");
         case PRICE_TYPICAL:  return("TYPICAL");
         case PRICE_WEIGHTED: return("WEIGHT");
        }
      return("?");
     }

   //--- low-level object helpers ----------------------------------
   void    Del(const string nm)
     {
      if(ObjectFind(m_chart,nm)>=0) ObjectDelete(m_chart,nm);
     }
   void    DelByBase(const string base)
     {
      int total=ObjectsTotal(m_chart,-1,-1);
      for(int i=total-1;i>=0;i--)
        {
         string nm=ObjectName(m_chart,i,-1,-1);
         if(StringFind(nm,base)==0) ObjectDelete(m_chart,nm);
        }
     }
   void    MkRect(const string nm,const int x,const int y,const int w,const int h,const color bg)
     {
      if(ObjectFind(m_chart,nm)<0)
        {
         ObjectCreate(m_chart,nm,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(m_chart,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chart,nm,OBJPROP_HIDDEN,true);
         ObjectSetInteger(m_chart,nm,OBJPROP_BACK,false);
         ObjectSetInteger(m_chart,nm,OBJPROP_CORNER,m_corner);
         ObjectSetInteger(m_chart,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
        }
      ObjectSetInteger(m_chart,nm,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chart,nm,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(m_chart,nm,OBJPROP_XSIZE,w);
      ObjectSetInteger(m_chart,nm,OBJPROP_YSIZE,h);
      ObjectSetInteger(m_chart,nm,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,m_headerColor);
     }
   void    MkBtn(const string nm,const string text,const int x,const int y,
                 const int w,const int h)
     {
      if(ObjectFind(m_chart,nm)<0)
        {
         ObjectCreate(m_chart,nm,OBJ_BUTTON,0,0,0);
         ObjectSetInteger(m_chart,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chart,nm,OBJPROP_HIDDEN,true);
         ObjectSetInteger(m_chart,nm,OBJPROP_CORNER,m_corner);
         ObjectSetInteger(m_chart,nm,OBJPROP_FONTSIZE,m_fontSize);
         ObjectSetString(m_chart,nm,OBJPROP_FONT,m_font);
        }
      ObjectSetInteger(m_chart,nm,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chart,nm,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(m_chart,nm,OBJPROP_XSIZE,w);
      ObjectSetInteger(m_chart,nm,OBJPROP_YSIZE,h);
      ObjectSetInteger(m_chart,nm,OBJPROP_BGCOLOR,m_btnColor);
      ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,m_btnTextColor);
      ObjectSetInteger(m_chart,nm,OBJPROP_BORDER_COLOR,m_headerColor);
      ObjectSetString(m_chart,nm,OBJPROP_TEXT,text);
     }
   void    MkLbl(const string nm,const string text,const int x,const int y,
                 const color fg,const int anchor=ANCHOR_LEFT)
     {
      if(ObjectFind(m_chart,nm)<0)
        {
         ObjectCreate(m_chart,nm,OBJ_LABEL,0,0,0);
         ObjectSetInteger(m_chart,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chart,nm,OBJPROP_HIDDEN,true);
         ObjectSetInteger(m_chart,nm,OBJPROP_BACK,false);
         ObjectSetInteger(m_chart,nm,OBJPROP_CORNER,m_corner);
         ObjectSetInteger(m_chart,nm,OBJPROP_FONTSIZE,m_fontSize);
         ObjectSetString(m_chart,nm,OBJPROP_FONT,m_font);
        }
      ObjectSetInteger(m_chart,nm,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chart,nm,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,fg);
      ObjectSetInteger(m_chart,nm,OBJPROP_ANCHOR,anchor);
      ObjectSetString(m_chart,nm,OBJPROP_TEXT,text);
     }
   void    MkRow(const string base,const string name,const string valTxt,
                 const int x,const int y)
     {
      int p=Pad(), nw=NameW(), sw=StepW(), vw=ValW();
      MkLbl(base+"_l",name,   x+p,                   y+1, m_textColor, ANCHOR_LEFT);
      MkBtn(base+"_p","<",    x+p+nw+2,              y,    sw, BtnH());
      MkLbl(base+"_v",valTxt, x+p+nw+2+sw+2+vw/2,     y+1, m_valColor, ANCHOR_CENTER);
      MkBtn(base+"_n",">",    x+p+nw+2+sw+2+vw+2,     y,    sw, BtnH());
     }

   //--- live-edit steppers ----------------------------------------
   void    StepEnumSens(const int dir)
     {
      int v=(int)g_Sensitivity+dir; if(v<0) v=3; if(v>3) v=0;
      g_Sensitivity=(ENUM_MDX_SENSITIVITY)v;
      ApplyCoreSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepEnumDiv(const int dir)
     {
      int v=(int)g_DivMode+dir; if(v<0) v=2; if(v>2) v=0;
      g_DivMode=(ENUM_MDX_DIVMODE)v;
      ApplyCoreSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepEnumPivot(const int dir)
     {
      int v=(int)g_PivotPolicy+dir; if(v<0) v=2; if(v>2) v=0;
      g_PivotPolicy=(ENUM_MDX_PIVOTPOLICY)v;
      ApplyCoreSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepEnumTrendF(const int dir)
     {
      int v=(int)g_TrendFilter+dir; if(v<0) v=3; if(v>3) v=0;
      g_TrendFilter=(ENUM_MDX_TRENDFILTER)v;
      ApplyTrendSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepEnumTrendM(const int dir)
     {
      int v=(int)g_TrendMode+dir; if(v<0) v=1; if(v>1) v=0;
      g_TrendMode=(ENUM_MDX_TRENDMODE)v;
      ApplyCoreSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepEnumPrice(const int dir)
     {
      int v=(int)g_TrendPrice+dir; if(v<1) v=7; if(v>7) v=1;
      g_TrendPrice=(ENUM_APPLIED_PRICE)v;
      ApplyTrendSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepMaxBars(const int dir)
     {
      g_MaxBarsToScan=MathMax(0,MathMin(10000,g_MaxBarsToScan+500*dir));
      g_forceRebuild=true; Refresh(); ChartRedraw(m_chart);
     }
   void    StepFastEMA(const int dir)
     {
      g_TrendFastEMA=MathMax(2,MathMin(500,g_TrendFastEMA+dir));
      ApplyTrendSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepSlowEMA(const int dir)
     {
      g_TrendSlowEMA=MathMax(3,MathMin(1000,g_TrendSlowEMA+dir));
      ApplyTrendSettings(); Refresh(); ChartRedraw(m_chart);
     }
   void    StepSlopeBars(const int dir)
     {
      g_TrendSlopeBars=MathMax(1,MathMin(50,g_TrendSlopeBars+dir));
      ApplyTrendSettings(); Refresh(); ChartRedraw(m_chart);
     }

public:
                     CMDXDashPanel(void)
     {
      m_chart=0; m_prefix="MDX_"; m_corner=0; m_x=12; m_y=18;
      m_fontSize=9; m_font="Arial";
      m_textColor=clrSilver; m_bgColor=C'18,18,22';
      m_headerColor=C'38,38,46'; m_btnColor=C'52,52,62';
      m_btnTextColor=clrWhiteSmoke; m_valColor=clrWhite;
      m_panelW=270; m_collapsed=false; m_coreOpen=true; m_trendOpen=true;
     }

   void    Init(const long chart,const string prefix,const int corner,
                const int x,const int y,const int fontSize,
                const string font,const color textColor)
     {
      m_chart=chart; m_prefix=prefix; m_corner=corner;
      m_x=x; m_y=y; m_fontSize=MathMax(7,fontSize); m_font=font;
      m_textColor=textColor;
     }

   void    Clear(void) { ObjectsDeleteAll(m_chart,m_prefix+"DP_",-1,-1); }

   void    ToggleMaster(void) { m_collapsed=!m_collapsed; }
   void    ToggleCore(void)   { m_coreOpen=!m_coreOpen; }
   void    ToggleTrend(void)  { m_trendOpen=!m_trendOpen; }

   //--- redraw the whole panel from current state + globals ---------
   void    Refresh(void)
     {
      int p=Pad(), W=m_panelW, rh=RowH();

      if(m_collapsed)
        {
         MkRect(m_prefix+"DP_BG",m_x,m_y,W,rh+p,m_bgColor);
         DelByBase(m_prefix+"DP_CORE_");
         DelByBase(m_prefix+"DP_TREND_");
         Del(m_prefix+"DP_COREHEAD");
         Del(m_prefix+"DP_TRENDHEAD");
         MkBtn(m_prefix+"DP_MASTER","[+]  MDX Settings",
               m_x+p,m_y+p,W-2*p,rh-2);
         return;
        }

      int rows=1+1+(m_coreOpen?4:0)+1+(m_trendOpen?6:0);
      int totalH=rows*rh+p;
      MkRect(m_prefix+"DP_BG",m_x,m_y,W,totalH,m_bgColor);

      int y=m_y+p;
      MkBtn(m_prefix+"DP_MASTER","[-]  MDX Settings",
            m_x+p,y,W-2*p,rh-2);
      y+=rh;

      MkBtn(m_prefix+"DP_COREHEAD",
            (m_coreOpen? "[-]  Core / Sensitivity":"[+]  Core / Sensitivity"),
            m_x+p,y,W-2*p,rh-2);
      y+=rh;
      if(m_coreOpen)
        {
         MkRow(m_prefix+"DP_CORE_0","Sensitivity", SensName(g_Sensitivity),          m_x,y); y+=rh;
         MkRow(m_prefix+"DP_CORE_1","Div Mode",    DivName(g_DivMode),                m_x,y); y+=rh;
         MkRow(m_prefix+"DP_CORE_2","Pivot Policy",PivotName(g_PivotPolicy),          m_x,y); y+=rh;
         MkRow(m_prefix+"DP_CORE_3","Max Bars",    IntegerToString(g_MaxBarsToScan), m_x,y); y+=rh;
        }
      else DelByBase(m_prefix+"DP_CORE_");

      MkBtn(m_prefix+"DP_TRENDHEAD",
            (m_trendOpen? "[-]  Trend Filter":"[+]  Trend Filter"),
            m_x+p,y,W-2*p,rh-2);
      y+=rh;
      if(m_trendOpen)
        {
         MkRow(m_prefix+"DP_TREND_0","Trend Filter",TrendFName(g_TrendFilter),         m_x,y); y+=rh;
         MkRow(m_prefix+"DP_TREND_1","Trend Mode",  TrendMName(g_TrendMode),           m_x,y); y+=rh;
         MkRow(m_prefix+"DP_TREND_2","Fast EMA",    IntegerToString(g_TrendFastEMA),   m_x,y); y+=rh;
         MkRow(m_prefix+"DP_TREND_3","Slow EMA",    IntegerToString(g_TrendSlowEMA),   m_x,y); y+=rh;
         MkRow(m_prefix+"DP_TREND_4","Slope Bars",  IntegerToString(g_TrendSlopeBars), m_x,y); y+=rh;
         MkRow(m_prefix+"DP_TREND_5","Trend Price", PriceName(g_TrendPrice),           m_x,y); y+=rh;
        }
      else DelByBase(m_prefix+"DP_TREND_");
     }

   //--- click dispatcher; returns true if the click was on the panel -
   bool    OnClick(const string name)
     {
      if(StringFind(name,m_prefix+"DP_")!=0) return(false);

      if(name==m_prefix+"DP_MASTER")    { ToggleMaster(); Refresh(); ChartRedraw(m_chart); return(true); }
      if(name==m_prefix+"DP_COREHEAD")  { ToggleCore();   Refresh(); ChartRedraw(m_chart); return(true); }
      if(name==m_prefix+"DP_TRENDHEAD") { ToggleTrend();  Refresh(); ChartRedraw(m_chart); return(true); }

      if(name==m_prefix+"DP_CORE_0_p"){ StepEnumSens(-1);  return(true); }
      if(name==m_prefix+"DP_CORE_0_n"){ StepEnumSens(+1);  return(true); }
      if(name==m_prefix+"DP_CORE_1_p"){ StepEnumDiv(-1);   return(true); }
      if(name==m_prefix+"DP_CORE_1_n"){ StepEnumDiv(+1);   return(true); }
      if(name==m_prefix+"DP_CORE_2_p"){ StepEnumPivot(-1); return(true); }
      if(name==m_prefix+"DP_CORE_2_n"){ StepEnumPivot(+1); return(true); }
      if(name==m_prefix+"DP_CORE_3_p"){ StepMaxBars(-1);   return(true); }
      if(name==m_prefix+"DP_CORE_3_n"){ StepMaxBars(+1);   return(true); }

      if(name==m_prefix+"DP_TREND_0_p"){ StepEnumTrendF(-1); return(true); }
      if(name==m_prefix+"DP_TREND_0_n"){ StepEnumTrendF(+1); return(true); }
      if(name==m_prefix+"DP_TREND_1_p"){ StepEnumTrendM(-1); return(true); }
      if(name==m_prefix+"DP_TREND_1_n"){ StepEnumTrendM(+1); return(true); }
      if(name==m_prefix+"DP_TREND_2_p"){ StepFastEMA(-1);   return(true); }
      if(name==m_prefix+"DP_TREND_2_n"){ StepFastEMA(+1);   return(true); }
      if(name==m_prefix+"DP_TREND_3_p"){ StepSlowEMA(-1);   return(true); }
      if(name==m_prefix+"DP_TREND_3_n"){ StepSlowEMA(+1);   return(true); }
      if(name==m_prefix+"DP_TREND_4_p"){ StepSlopeBars(-1); return(true); }
      if(name==m_prefix+"DP_TREND_4_n"){ StepSlopeBars(+1); return(true); }
      if(name==m_prefix+"DP_TREND_5_p"){ StepEnumPrice(-1); return(true); }
      if(name==m_prefix+"DP_TREND_5_n"){ StepEnumPrice(+1); return(true); }

      return(true);
     }
  };

CMDXDashPanel g_dash;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   //--- runtime-editable working copies (dashboard can mutate these) -
   g_Sensitivity   = InpSensitivity;
   g_DivMode       = InpDivMode;
   g_PivotPolicy   = InpPivotPolicy;
   g_MaxBarsToScan = InpMaxBarsToScan;
   g_TrendFilter   = InpTrendFilter;
   g_TrendMode     = InpTrendMode;
   g_TrendFastEMA  = InpTrendFastEMA;
   g_TrendSlowEMA  = InpTrendSlowEMA;
   g_TrendSlopeBars= InpTrendSlopeBars;
   g_TrendPrice    = InpTrendPrice;
   g_forceRebuild  = false;

   ApplySensitivityPreset();

   //--- buffer binding -------------------------------------------
   SetIndexBuffer(0,BufBull,   INDICATOR_DATA);
   SetIndexBuffer(1,BufBear,   INDICATOR_DATA);
   SetIndexBuffer(2,BufHidBull,INDICATOR_DATA);
   SetIndexBuffer(3,BufHidBear,INDICATOR_DATA);
   SetIndexBuffer(4,BufScore,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(5,BufAgree,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(6,BufMask,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,BufTrend,  INDICATOR_CALCULATIONS);

   //--- non-series layout everywhere (0 == oldest) for cache-friendly loops
   ArraySetAsSeries(BufBull,false);
   ArraySetAsSeries(BufBear,false);
   ArraySetAsSeries(BufHidBull,false);
   ArraySetAsSeries(BufHidBear,false);
   ArraySetAsSeries(BufScore,false);
   ArraySetAsSeries(BufAgree,false);
   ArraySetAsSeries(BufMask,false);
   ArraySetAsSeries(BufTrend,false);

   PlotIndexSetInteger(0,PLOT_ARROW,InpArrowBull);
   PlotIndexSetInteger(1,PLOT_ARROW,InpArrowBear);
   PlotIndexSetInteger(2,PLOT_ARROW,InpArrowHidBull);
   PlotIndexSetInteger(3,PLOT_ARROW,InpArrowHidBear);

   for(int p=0;p<4;p++)
     {
      PlotIndexSetDouble(p,PLOT_EMPTY_VALUE,EMPTY_VALUE);
      PlotIndexSetInteger(p,PLOT_DRAW_BEGIN,0);
      PlotIndexSetInteger(p,PLOT_SHOW_DATA,true);
     }
   if(!InpShowArrows)
      for(int p=0;p<4;p++) PlotIndexSetInteger(p,PLOT_DRAW_TYPE,DRAW_NONE);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("MDX Divergence [%s|%s]",
                                   EnumToString(g_Sensitivity),
                                   EnumToString(g_DivMode)));
   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);

   //--- oscillator bank ------------------------------------------
   MDXOscConfig oc;
   oc.useRSI  = InpUseRSI;   oc.rsiPeriod = MathMax(2,InpRSIPeriod); oc.rsiPrice = InpRSIPrice;
   oc.useCCI  = InpUseCCI;   oc.cciPeriod = MathMax(2,InpCCIPeriod); oc.cciPrice = InpCCIPrice;
   oc.useMOM  = InpUseMOM;   oc.momPeriod = MathMax(2,InpMOMPeriod); oc.momPrice = InpMOMPrice;
   oc.useSTO  = InpUseSTO;   oc.stoK = MathMax(2,InpSTOK); oc.stoD = MathMax(1,InpSTOD);
   oc.stoSlow = MathMax(1,InpSTOSlow);  oc.stoPriceField = InpSTOField;
   oc.useMACD = InpUseMACD;
   oc.macdFast   = MathMax(2,InpMACDFast);
   oc.macdSlow   = MathMax(oc.macdFast+1,InpMACDSlow);
   oc.macdSignal = MathMax(1,InpMACDSignal);
   oc.macdPrice  = InpMACDPrice;
   oc.macdUseHistogram = InpMACDHistogram;

   if(!g_bank.Init(_Symbol,PERIOD_CURRENT,oc))
     {
      Print("MDX: oscillator bank initialisation failed");
      return(INIT_FAILED);
     }

   //--- pivots ----------------------------------------------------
   MDXPivotConfig pc;
   pc.leftBars          = g_effLeft;
   pc.rightBarsConf     = g_effRightConf;
   pc.rightBarsTent     = g_effRightTent;
   pc.policy            = g_PivotPolicy;
   pc.useWicks          = InpUseWicks;
   pc.minAtrDisplace    = g_effMinAtrDisp;
   pc.requireStrictLeft = InpStrictLeft;
   g_engine.SetPivotConfig(pc);

   //--- scoring ---------------------------------------------------
   MDXScoreConfig sc;
   sc.weight[MDX_OSC_RSI]   = MathMax(0.0,InpWeightRSI);
   sc.weight[MDX_OSC_CCI]   = MathMax(0.0,InpWeightCCI);
   sc.weight[MDX_OSC_MOM]   = MathMax(0.0,InpWeightMOM);
   sc.weight[MDX_OSC_STOCH] = MathMax(0.0,InpWeightSTO);
   sc.weight[MDX_OSC_MACD]  = MathMax(0.0,InpWeightMACD);
   sc.conflictPenalty   = MathMax(0.0,InpConflictPenalty);
   sc.minScore          = MDX_Clamp(g_effMinScore,0.0,100.0);
   sc.minAgree          = MathMax(1,g_effMinAgree);
   sc.noiseBandPct      = MathMax(0.0,InpNoiseBandPct);
   sc.tentativePenalty  = InpTentativePenalty;
   sc.hiddenPenalty     = InpHiddenPenalty;
   sc.trendPenalty      = InpTrendPenalty;
   sc.volPenalty        = InpVolPenalty;
   sc.priceQualityWeight= MDX_Clamp(InpPriceQualityW,0.0,1.0);
   sc.slopeQualityWeight= 0.5;
   g_engine.SetScoreConfig(sc);

   //--- engine ----------------------------------------------------
   MDXEngineConfig ec;
   ec.divMode           = g_DivMode;
   ec.maxPivotLookback  = MathMax(1,InpMaxPivotLookback);
   ec.minBarGap         = MathMax(1,InpMinBarGap);
   ec.maxBarGap         = MathMax(ec.minBarGap+1,InpMaxBarGap);
   ec.idealMinGap       = MathMax(1,InpIdealMinGap);
   ec.idealMaxGap       = MathMax(ec.idealMinGap+1,InpIdealMaxGap);
   ec.allowMultiPair    = InpAllowMultiPair;
   ec.requireCloseBreak = false;
   ec.minPriceDeltaAtr  = MathMax(0.0,InpMinPriceDeltaATR);
   ec.trendMode         = g_TrendMode;
   g_engine.SetEngineConfig(ec);
   g_engine.ResetAll();

   //--- filters ---------------------------------------------------
   if(!g_trend.Init(_Symbol,PERIOD_CURRENT,g_TrendFilter,
                    g_TrendFastEMA,g_TrendSlowEMA,g_TrendSlopeBars,g_TrendPrice))
     {
      Print("MDX: trend filter initialisation failed");
      return(INIT_FAILED);
     }

   if(!g_vol.Init(_Symbol,PERIOD_CURRENT,InpATRPeriod,InpUseVolFilter,
                  InpATRMinMult,InpATRMaxMult,InpATRAvgLen))
     {
      Print("MDX: ATR initialisation failed");
      return(INIT_FAILED);
     }

   g_session.Init(InpUseSession,InpSess1From,InpSess1To,InpSess2From,InpSess2To,
                  InpSess3From,InpSess3To,InpSkipFridayLate,InpFridayCutoff,
                  InpSkipMondayEarly,InpMondayOpen);

   //--- render + alerts -------------------------------------------
   g_render.Init(ChartID(),0,MDX_OBJ_PREFIX,InpDrawLines,InpDrawScoreLabels,
                 clrDodgerBlue,clrOrangeRed,clrMediumSeaGreen,clrMediumVioletRed,
                 1,STYLE_SOLID,InpLabelFontSize,InpLabelFont,InpMaxChartObjects);
   g_render.CleanAll();

   g_dash.Init(ChartID(),MDX_OBJ_PREFIX,InpDashCorner,InpDashX,InpDashY,
               InpDashFontSize,InpLabelFont,InpDashColor);
   if(InpShowDashboard) g_dash.Refresh();

   g_alerts.Init(InpAlertPopup,InpAlertSound,InpAlertPush,InpAlertEmail,
                 InpSoundBull,InpSoundBear,InpAlertMode,InpAlertOnEarly,
                 _Symbol,PERIOD_CURRENT,InpAlertCooldownSec);
   g_alerts.Reset();

   //--- warmup ----------------------------------------------------
   g_warmup=MathMax(g_bank.WarmupBars(),
            MathMax(g_trend.WarmupBars(),g_vol.WarmupBars()));
   g_warmup=MathMax(g_warmup,g_effLeft+g_effRightConf+5)+10;

   g_lastCalc=0;
   g_lastBarTime=0;
   MDX_ResetResult(g_lastSignal);
   g_lastSignalTime=0;
   g_initOK=true;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_dash.Clear();
   g_render.CleanAll();
   g_bank.Deinit();
   g_trend.Deinit();
   g_vol.Deinit();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Write a signal into the plotting buffers                          |
//+------------------------------------------------------------------+
void PlotSignal(const MDXResult &r,const int i,
                const double &high[],const double &low[],const double atr)
  {
   double off=(atr>0.0? atr*InpArrowOffsetATR : 10*_Point);
   bool bull=MDX_IsBull(r.type);
   double y=(bull? low[i]-off : high[i]+off);

   switch(r.type)
     {
      case MDX_DIV_REG_BULL: BufBull[i]=y;    break;
      case MDX_DIV_REG_BEAR: BufBear[i]=y;    break;
      case MDX_DIV_HID_BULL: BufHidBull[i]=y; break;
      case MDX_DIV_HID_BEAR: BufHidBear[i]=y; break;
      default: return;
     }

   BufScore[i] = (bull? r.score : -r.score);
   BufAgree[i] = (double)r.agree;
   BufMask[i]  = (double)r.mask;
  }

//+------------------------------------------------------------------+
//| Clear all signal buffers at bar i                                 |
//+------------------------------------------------------------------+
void ClearBufsAt(const int i)
  {
   BufBull[i]=EMPTY_VALUE;
   BufBear[i]=EMPTY_VALUE;
   BufHidBull[i]=EMPTY_VALUE;
   BufHidBear[i]=EMPTY_VALUE;
   BufScore[i]=0.0;
   BufAgree[i]=0.0;
   BufMask[i]=0.0;
   BufTrend[i]=0.0;
  }

//+------------------------------------------------------------------+
//| Dashboard refresh                                                 |
//+------------------------------------------------------------------+
void RefreshDashboard(void)
  {
   if(!InpShowDashboard)
     {
      g_dash.Clear();
      return;
     }
   g_dash.Refresh();
  }

//+------------------------------------------------------------------+
//| OnChartEvent  (dashboard interaction)                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_OBJECT_CLICK)
      g_dash.OnClick(sparam);
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(!g_initOK) return(0);
   if(rates_total<g_warmup+20) return(0);

   //--- work in non-series layout so index 0 == oldest bar
   ArraySetAsSeries(time,false);
   ArraySetAsSeries(open,false);
   ArraySetAsSeries(high,false);
   ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false);

   //--- how much history to actually process
   int scanLimit=(g_MaxBarsToScan<=0? rates_total : MathMin(rates_total,g_MaxBarsToScan));
   int firstBar=MathMax(g_warmup,rates_total-scanLimit);

   bool fullRebuild=(prev_calculated<=0 || prev_calculated>rates_total ||
                     rates_total-prev_calculated>2 || g_forceRebuild);
   g_forceRebuild=false;

   //--- refresh dependent series ---------------------------------
   int needed=MathMin(rates_total, scanLimit+g_warmup+50);
   if(!g_bank.Refresh(rates_total,needed))    return(prev_calculated);
   if(!g_vol.Refresh(rates_total,needed))     return(prev_calculated);
   if(!g_trend.Refresh(rates_total,needed))   { /* trend optional - continue */ }

   //--- initialise / reset buffers -------------------------------
   int start;
   if(fullRebuild)
     {
      for(int i=0;i<rates_total;i++) ClearBufsAt(i);
      g_engine.ResetAll();
      g_render.CleanAll();
      start=firstBar;
     }
   else
     {
      start=MathMax(firstBar,prev_calculated-2);
      for(int i=start;i<rates_total;i++) ClearBufsAt(i);
     }

   //--- the newest fully-closed bar index
   int lastClosed=rates_total-2;
   if(lastClosed<start) lastClosed=start;

   //=================================================================
   //  MAIN LOOP
   //  We iterate bar by bar. For every bar we:
   //    (a) refresh the trend bias buffer,
   //    (b) prune invalidated tentative pivots,
   //    (c) test whether an older bar just became a pivot,
   //    (d) if a new/updated pivot appeared, run divergence scoring.
   //=================================================================
   bool allowTentative=(g_PivotPolicy!=MDX_PIVOT_CONFIRMED);

   for(int i=start;i<rates_total;i++)
     {
      //--- (a) trend bias for this bar
      int tb=g_trend.Bias(i,close,high,low);
      BufTrend[i]=(double)tb;

      //--- current-bar context values
      double atr=g_vol.ATR(i);
      bool   volOK=g_vol.Pass(i);
      bool   sessOK=g_session.Pass(time[i]);

      //--- (b) invalidate stale tentative pivots
      g_engine.PruneTentative(i,high,low,open,close);

      //--- (c) pivot candidates:
      //        confirmed  -> bar i-rightConf
      //        tentative  -> bar i-rightTent
      int changed=0;

      int cConf=i-g_effRightConf;
      if(cConf>=g_warmup)
         changed|=g_engine.ScanPivotAt(cConf,rates_total,high,low,open,close,time,
                                       g_bank,atr,false);

      if(allowTentative && g_effRightTent<g_effRightConf)
        {
         int cTent=i-g_effRightTent;
         if(cTent>=g_warmup)
            changed|=g_engine.ScanPivotAt(cTent,rates_total,high,low,open,close,time,
                                          g_bank,atr,true);
        }

      if(changed==0) continue;

      //--- (d) evaluate divergence families that just gained a pivot
      MDXResult r;

      //--- bullish family (new swing LOW)
      if((changed&2)!=0)
        {
         if(g_engine.EvaluateBullish(g_bank,atr,tb,volOK,r))
           {
            bool blocked=false;

            if(g_TrendFilter!=MDX_TREND_OFF && g_TrendMode==MDX_TRENDMODE_BLOCK)
              {
               //--- regular bullish needs non-bearish context,
               //    hidden bullish needs bullish context
               if(r.type==MDX_DIV_REG_BULL && tb<0) blocked=true;
               if(r.type==MDX_DIV_HID_BULL && tb<=0) blocked=true;
              }
            if(InpUseVolFilter && !volOK) blocked=true;
            if(!sessOK) blocked=true;

            if(!blocked && g_engine.Passes(r) &&
               !g_engine.FiredOnPivot(r.barTime,(int)r.type))
              {
               //--- locate the older pivot for drawing
               MDXPivot p2,p1;
               bool haveP2=g_engine.Lows().Get(0,p2);
               bool drawn=false;
               for(int b=1;b<=InpMaxPivotLookback && haveP2;b++)
                 {
                  if(!g_engine.Lows().Get(b,p1)) break;
                  int gap=p2.bar-p1.bar;
                  if(gap<InpMinBarGap || gap>InpMaxBarGap) continue;
                  bool ok=(r.type==MDX_DIV_REG_BULL? (p2.price<p1.price) : (p2.price>p1.price));
                  if(ok)
                    {
                     g_render.DrawLink(p1.time,p1.price,p2.time,p2.price,
                                       r.type,r.score,r.tentative);
                     drawn=true;
                     break;
                    }
                 }
               if(!drawn){ /* nothing to draw - still emit the signal */ }

               //--- plot on the pivot bar itself (earliest visual location)
               int plotBar=r.barIndex;
               if(plotBar>=0 && plotBar<rates_total)
                 {
                  PlotSignal(r,plotBar,high,low,atr);
                  g_render.DrawScoreLabel(time[plotBar],low[plotBar]-
                                          (atr>0? atr*(InpArrowOffsetATR+0.45):20*_Point),
                                          r.type,r.score,MaskToText(r.mask),true);
                 }

               g_engine.Remember(0,r.barTime,(int)r.type);
               g_lastSignal=r;
               g_lastSignalTime=time[i];

               //--- alert only for the live-edge bar
               bool realtime=(i>=rates_total-2) && !fullRebuild;
               g_alerts.Fire(r,time[i],close[i],MaskToText(r.mask),tb,realtime);
              }
           }
        }

      //--- bearish family (new swing HIGH)
      if((changed&1)!=0)
        {
         if(g_engine.EvaluateBearish(g_bank,atr,tb,volOK,r))
           {
            bool blocked=false;

            if(g_TrendFilter!=MDX_TREND_OFF && g_TrendMode==MDX_TRENDMODE_BLOCK)
              {
               if(r.type==MDX_DIV_REG_BEAR && tb>0) blocked=true;
               if(r.type==MDX_DIV_HID_BEAR && tb>=0) blocked=true;
              }
            if(InpUseVolFilter && !volOK) blocked=true;
            if(!sessOK) blocked=true;

            if(!blocked && g_engine.Passes(r) &&
               !g_engine.FiredOnPivot(r.barTime,(int)r.type))
              {
               MDXPivot p2,p1;
               bool haveP2=g_engine.Highs().Get(0,p2);
               for(int b=1;b<=InpMaxPivotLookback && haveP2;b++)
                 {
                  if(!g_engine.Highs().Get(b,p1)) break;
                  int gap=p2.bar-p1.bar;
                  if(gap<InpMinBarGap || gap>InpMaxBarGap) continue;
                  bool ok=(r.type==MDX_DIV_REG_BEAR? (p2.price>p1.price) : (p2.price<p1.price));
                  if(ok)
                    {
                     g_render.DrawLink(p1.time,p1.price,p2.time,p2.price,
                                       r.type,r.score,r.tentative);
                     break;
                    }
                 }

               int plotBar=r.barIndex;
               if(plotBar>=0 && plotBar<rates_total)
                 {
                  PlotSignal(r,plotBar,high,low,atr);
                  g_render.DrawScoreLabel(time[plotBar],high[plotBar]+
                                          (atr>0? atr*(InpArrowOffsetATR+0.45):20*_Point),
                                          r.type,r.score,MaskToText(r.mask),false);
                 }

               g_engine.Remember(0,r.barTime,(int)r.type);
               g_lastSignal=r;
               g_lastSignalTime=time[i];

               bool realtime=(i>=rates_total-2) && !fullRebuild;
               g_alerts.Fire(r,time[i],close[i],MaskToText(r.mask),tb,realtime);
              }
           }
        }
     }

   //--- housekeeping & dashboard ---------------------------------
   g_render.Housekeep();

   RefreshDashboard();

   if(fullRebuild) ChartRedraw();

   g_lastCalc=rates_total;
   g_lastBarTime=time[rates_total-1];

   return(rates_total);
  }
//+------------------------------------------------------------------+
