from multiprocessing import Pool, cpu_count
from pathlib import Path
from MLToolkit.Visualisation import ImageDatasetVisualiser
import cv2
import numpy as np
import pandas as pd

REAL_LABELS = ["Real", "real", "REAL"]
PHOTOCOPY_LABELS = ["Photocopy", "photocopy", "PHOTOCOPY", "fake", "fakes", "Fakes", "Fake"]

def did_pass_qc(row):
    sharpnessPass = row["checkFrameSharpness"] < 0.2579
    specularReflectionPass = row["checkSpecularReflection"] < 1.05
    return all([sharpnessPass, specularReflectionPass])

if __name__ == "__main__":
    pool = Pool(cpu_count())
    qc_csv_paths = [
        "/Users/blake/Desktop/iPhone 13 Mini Q0a data.csv"
    ]
    qc_df = pd.concat(map(pd.read_csv, qc_csv_paths))
    reals = qc_df[qc_df["filepath"].apply(lambda path: any([label in path for label in REAL_LABELS]))]

    qc_df["didPassQC"] = qc_df.apply(did_pass_qc, axis='columns')
    qc_df.to_csv("iPhone 13 Mini QC output.csv")

    # print(reals.shape)
    # reals = reals[reals["checkFrameSharpness"] < 0.2579]
    # print(reals.shape)
    # reals = reals[reals["checkSpecularReflection"] < 1.05]
    # print(reals.shape)

    qc_checks = set(qc_df.columns).difference(["filepath"])
     
    for qc_check_name in qc_checks:
        # this_check_data = reals[qc_check_name]
        # q1 = np.percentile(this_check_data, 25)
        # q3 = np.percentile(this_check_data, 75)
        # iqr = q3 - q1
        # lower_bound = q1 - (1.5 * iqr)
        # upper_bound = q3 + (1.5 * iqr)
        # outlier_mask = this_check_data.between(lower_bound, upper_bound) == False

        # outliers = reals[outlier_mask]
        # print(qc_check_name, "number of outliers:", outliers.shape[0])
        # if outliers.shape[0] == 0: continue

        indexes_to_sort = np.argsort(reals[qc_check_name].values)
        images = pool.map(cv2.imread, reals["filepath"])
        sorted_images = [images[i] for i in indexes_to_sort]
        vis = ImageDatasetVisualiser(sorted_images, reals[qc_check_name].values[indexes_to_sort].round(5))

        number_of_splices = 5
        chunk_length = len(sorted_images) // 5
        vis.numberOfImagesInRow=chunk_length
        vis.imageSize = 500,500
        for i in range(number_of_splices):
            start_index = i * chunk_length
            vis.currentlyViewing = start_index
            cv2.imwrite(f"{qc_check_name} {i}.png", vis.createVisualisation())