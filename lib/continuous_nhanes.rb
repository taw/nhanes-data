# Continuous NHANES (1999+) cycles. CDC publishes each two-year cycle as
# separate SAS transport files, named <stem><suffix>.xpt: no suffix for
# 1999-2000, _B for 2001-2002 and so on.
#
# 2017-2018 (_J) is not included: fieldwork for 2019-2020 stopped in March
# 2020, and CDC merged the partial cycle with 2017-2018 into the 2017-March
# 2020 pre-pandemic files (P_ prefix), which cover the same people and more.

module ContinuousNhanes
  # survey name => [CDC cycle, data directory year]
  CYCLES = {
    "nhanes_1999_2000" => ["1999-2000", 1999],
    "nhanes_2001_2002" => ["2001-2002", 2001],
    "nhanes_2003_2004" => ["2003-2004", 2003],
    "nhanes_2005_2006" => ["2005-2006", 2005],
    "nhanes_2007_2008" => ["2007-2008", 2007],
    "nhanes_2009_2010" => ["2009-2010", 2009],
    "nhanes_2011_2012" => ["2011-2012", 2011],
    "nhanes_2013_2014" => ["2013-2014", 2013],
    "nhanes_2015_2016" => ["2015-2016", 2015],
    "nhanes_2017_2020" => ["2017-2020", 2017],
    "nhanes_2021_2023" => ["2021-2023", 2021],
  }
  COMPONENTS = %w[Demographics Dietary Examination Laboratory Questionnaire]

  module_function

  # File name without the cycle suffix or prefix: BMX_I -> BMX, P_DEMO -> DEMO
  def stem(basename)
    basename.sub(/\AP_/, "").sub(/_[B-L]\z/, "")
  end
end
