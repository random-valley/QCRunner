
from matplotlib import pyplot as plt
import pandas as pd

REAL_LABELS = ["Real", "real", "REAL"]
PHOTOCOPY_LABELS = ["Photocopy", "photocopy", "PHOTOCOPY", "fake", "fakes", "Fakes", "Fake"]

if __name__ == "__main__":

    qc_csv_paths = [
        "/Users/blake/Desktop/iPhone 13 Mini Q0a data.csv"
    ]
    qc_df = pd.concat(map(pd.read_csv, qc_csv_paths))


    reals = qc_df[qc_df["filepath"].apply(lambda path: any([label in path for label in REAL_LABELS]))]
    photocopies = qc_df[qc_df["filepath"].apply(lambda path: any([label in path for label in PHOTOCOPY_LABELS]))]
    
    qc_checks = set(qc_df.columns).difference(["filepath"])
    for qc_check_name in qc_checks:

        plt.figure(figsize=(20, 10))

        plt.title("iPhone 13 Mini Q0a QC data")
        plt.boxplot([reals[qc_check_name], photocopies[qc_check_name]])
        plt.xticks(range(3), ["", "Reals", "Photocopies"])
        plt.ylabel(qc_check_name)
        plt.savefig(fname=f"{qc_check_name}.png")
