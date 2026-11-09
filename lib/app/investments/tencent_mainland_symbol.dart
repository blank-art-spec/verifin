/// 腾讯内地证券代码的交易所路由，供公开身份搜索与行情请求共同使用。
library;

/// 按交易所代码号段返回 [symbol] 的腾讯前缀（sh、sz 或 bj）。
///
/// [symbol] 必须是保留原样的六位数字证券代码；返回 null 表示当前没有明确路由。
/// 沪市明确的 ETF/LOF 交易号段与 6 开头股票、深市 0/3 开头股票及 15–18 开头
/// 的基金候选号段、北交所 920 新号段使用不同来源前缀，不能只用首位猜全部品种。
/// 不开放整个 1 开头号段，避免把债券的每百元报价当作每股份额价格。
/// 本函数仅路由，不证明证券挂牌、品种或币种；调用方仍须核对来源身份和币种。
/// 场内基金在股票/ETF 入口按成交价估值，不等同于基金申购入口的单位净值。
/// 号段依据及真实接口样例见 docs/dev/public-quote-research.md。
String? tencentMainlandExchangeForSymbol(String symbol) {
  if (RegExp(r'^6\d{5}$').hasMatch(symbol)) return 'sh';
  if (RegExp(r'^[03]\d{5}$').hasMatch(symbol)) return 'sz';
  if (isTencentMainlandExchangeFundSymbol(symbol)) {
    return symbol.startsWith('5') ? 'sh' : 'sz';
  }
  if (RegExp(r'^920\d{3}$').hasMatch(symbol)) return 'bj';
  return null;
}

/// 判断 [symbol] 是否位于当前允许尝试的内地 ETF/LOF 交易代码范围。
/// 沪市依据 2026 年第 3 次证券代码段分配指南，仅接受明确的 ETF/LOF 号段：
/// https://www.sse.com.cn/lawandrules/guide2025/stock/jyglywznylc/zn/c/c_20260831_10830433.shtml 。
/// 520 仅分配 520500–520999，506 的 LOF 仅分配 506000–506099；不泛开全部 5 号段。
/// 519 申赎、521–524 非交易业务、580 权证及 582 行权不属于每份成交价；
/// 尚未核对来源类型的封闭式基金、公募 REITs 及未明确业务号段也不新增覆盖。
/// 深市沿用 15–18 基金候选号段；此函数不是品种认证，响应和搜索仍必须为 ETF/LOF。
bool isTencentMainlandExchangeFundSymbol(String symbol) {
  if (!RegExp(r'^\d{6}$').hasMatch(symbol)) return false;
  if (RegExp(r'^1[5-8]\d{4}$').hasMatch(symbol)) return true;
  final prefix = symbol.substring(0, 3);
  if (prefix == '520') return symbol.compareTo('520500') >= 0;
  if (prefix == '506') return symbol.compareTo('506099') <= 0;
  return const {
    '501',
    '502',
    '510',
    '511',
    '512',
    '513',
    '515',
    '516',
    '517',
    '518',
    '526',
    '530',
    '551',
    '560',
    '561',
    '562',
    '563',
    '565',
    '566',
    '567',
    '581',
    '587',
    '588',
    '589',
  }.contains(prefix);
}
