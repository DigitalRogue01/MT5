#property strict
#property description "Minimal ONNX Camarilla demo EA"
#property version   "1.00"

input string InpOnnxModelName = "camarilla_levels.onnx";
input bool   InpUseOnnx = true;

long g_model = INVALID_HANDLE;

void ComputeNativeCamarilla(const double high, const double low, const double close,
                            double &h1, double &h2, double &h3, double &h4,
                            double &l1, double &l2, double &l3, double &l4)
{
   double range = high - low;
   double scale = range * 1.1;

   h1 = close + scale / 12.0;
   h2 = close + scale / 6.0;
   h3 = close + scale / 4.0;
   h4 = close + scale / 2.0;

   l1 = close - scale / 12.0;
   l2 = close - scale / 6.0;
   l3 = close - scale / 4.0;
   l4 = close - scale / 2.0;
}

int OnInit()
{
   double ph = iHigh(_Symbol, PERIOD_D1, 1);
   double pl = iLow(_Symbol, PERIOD_D1, 1);
   double pc = iClose(_Symbol, PERIOD_D1, 1);

   double h1,h2,h3,h4,l1,l2,l3,l4;
   ComputeNativeCamarilla(ph, pl, pc, h1,h2,h3,h4,l1,l2,l3,l4);

   PrintFormat("Native Camarilla: H1=%.5f H2=%.5f H3=%.5f H4=%.5f | L1=%.5f L2=%.5f L3=%.5f L4=%.5f",
               h1,h2,h3,h4,l1,l2,l3,l4);
   return(INIT_SUCCEEDED);
}

void OnTick() {}
