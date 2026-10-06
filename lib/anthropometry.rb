# Height and weight of examined persons in every survey in data/, in common
# units, for example analyses (bin/analyze_bmi, bin/analyze_height).
#
# Sources (units and implied decimals are from the PDF codebooks):
#   nhes1    DU1003 height (in, 1 decimal) and weight (lb, 1 decimal),
#            age and sex from DU1001, whose SEQN is DU1003's minus 10000
#   nhes2    growthch SURVEY=1 (NHES II has no height/weight in DU2idt)
#   nhes3    growthch SURVEY=2 (DU3edt has weight but no stature)
#   nhanes1  DU4111, 1971-74 sample only (weight for locations 1-65);
#            the 1974-75 augmentation (adults 25-74) has no such weight
#   nhanes2  DU5301
#   nhanes3  exam
#   nhanes_<cycle>  continuous NHANES, BMX joined to DEMO on SEQN; ages are
#            top-coded (85 = 85+ until 2005-2006, 80 = 80+ after)

require "json"
require_relative "continuous_nhanes"

module Anthropometry
  ROOT = File.expand_path("..", __dir__)

  # Every source yields sex (1 male, 2 female), age, weight kg, height cm,
  # sample weight. Missing values are nil or false.
  SOURCES = {
    "nhes1" => lambda do |&block|
      demographics = {}
      each_record("nhes1", "DU1001") { |r| demographics[r["SEQN"] + 10000] = r.values_at("H1DM0009", "H1DM0006") }
      each_record("nhes1", "DU1003") do |r|
        sex, age = demographics.fetch(r["SEQN"])
        height, weight = r.values_at("H1BM0013", "H1BM0016")
        block.(sex, age, weight && weight / 10.0 * 0.45359237, height && height / 10.0 * 2.54, r["H1BM0007"])
      end
    end,
    "nhes2" => ->(&block) { growth_chart(1, &block) },
    "nhes3" => ->(&block) { growth_chart(2, &block) },
    "nhanes1" => lambda do |&block|
      each_record("nhanes1", "DU4111") do |r|
        weight, height = r.values_at("N1BM0260", "N1BM0266")
        block.(r["N1BM0104"], r["N1BM0144"], weight && weight != 88888 && weight / 100.0,
               height && height != 8888 && height / 10.0, r["N1BM0176"])
      end
    end,
    "nhanes2" => lambda do |&block|
      each_record("nhanes2", "DU5301") do |r|
        weight, height = r.values_at("N2BM0412", "N2BM0418")
        block.(r["N2BM0055"], r["N2BM0190"], weight && weight / 100.0,
               height && height != 9999 && height / 10.0, r["N2BM0282"])
      end
    end,
    "nhanes3" => lambda do |&block|
      each_record("nhanes3", "exam") do |r|
        weight, height = r.values_at("BMPWT", "BMPHT")
        block.(r["HSSEX"], r["HSAGEIR"], weight && weight < 888 && weight,
               height && height < 888 && height, r["WTPFEX6"])
      end
    end,
  }
  ContinuousNhanes::CYCLES.each_key do |survey|
    SOURCES[survey] = ->(&block) { continuous(survey, &block) }
  end

  def self.each_record(survey, dataset)
    IO.popen(["zstdcat", File.join(ROOT, "data", survey, "#{dataset}.jsonl.zst")]) do |io|
      io.each_line { |line| yield JSON.parse(line) }
    end
  end

  def self.growth_chart(survey_number, &block)
    each_record("nhes2", "growthch") do |r|
      next unless r["SURVEY"] == survey_number
      block.(r["SEX"], r["AGE_EXAM"], r["WT_KG"], r["HT_CM"], r["STATWT"])
    end
  end

  # BMX joined to DEMO. The 2017-March 2020 files have their own exam weight.
  def self.continuous(survey, &block)
    sample_weight = survey == "nhanes_2017_2020" ? "WTMECPRP" : "WTMEC2YR"
    demographics = {}
    each_record(survey, "DEMO") { |r| demographics[r["SEQN"]] = r.values_at("RIAGENDR", "RIDAGEYR", sample_weight) }
    each_record(survey, "BMX") do |r|
      sex, age, weight = demographics.fetch(r["SEQN"])
      block.(sex, age, r["BMXWT"], r["BMXHT"], weight)
    end
  end

  # Prints the survey-weighted mean of the block's value (nil to skip a
  # person) by sex and single year of age, ages 2+, one JSON line per group.
  def self.report(surveys, name)
    surveys = SOURCES.keys if surveys.empty?
    unknown = surveys - SOURCES.keys
    abort "Unknown survey(s): #{unknown.join(", ")}. Known: #{SOURCES.keys.join(", ")}" unless unknown.empty?

    surveys.each do |survey|
      # [sex, age] => [sum of sample weight * value, sum of sample weights, count]
      groups = Hash.new { |h, k| h[k] = [0.0, 0.0, 0] }
      SOURCES[survey].call do |sex, age, weight_kg, height_cm, sample_weight|
        next unless [1, 2].include?(sex) && age && age >= 2 && sample_weight&.positive?
        value = yield(weight_kg || nil, height_cm || nil)
        next unless value
        group = groups[[sex, age]]
        group[0] += sample_weight * value
        group[1] += sample_weight
        group[2] += 1
      end
      groups.sort.each do |(sex, age), (weighted_sum, total_weight, count)|
        puts JSON.generate(:sex => sex == 1 ? "M" : "F", :age => age, name => (weighted_sum / total_weight).round(1),
                           :n => count, :survey => survey)
      end
    end
  end
end
