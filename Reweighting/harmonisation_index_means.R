# Investigation into Index Means Based Harmonisation
## Author: Paul Scherer
##         Tom Bishop
## Institute: University of Cambridge MRC Epidemiology Unit 
## Date: 4.09.2017

###############################################################################
###################### R Environment Settings #################################
###############################################################################
library(ggplot2)
library(reshape2)
library(parallel)

###############################################################################
########################### DATA AND SETTINGS #################################
###############################################################################
# Calculate the number of cores and initiate cluster
no_cores <- detectCores() - 1
cl <- makeCluster(no_cores)

# Base Data set properties
set_beta <- 0.5
constant <- 20

study_size <- 20000
raw_mean <- 45
raw_stdev = 15
study_data = data.frame(gold =  rnorm(n = study_size, mean = raw_mean, sd = raw_stdev))
study_data$foo = rnorm(length(study_data$gold), (set_beta*study_data$gold) + constant, 10)

###############################################################################
########################### Functions #########################################
###############################################################################
updateStudyData <- function(coh_base, study_data, number_of_indices){
	measurement_error = rnorm(n = study_size, mean = 0, sd = coh_base$std_dev[1])
	study_data$measured_exposure = study_data$gold + measurement_error
	study_data$index = cut_number(x = study_data$measured_exposure,n = number_of_indices, labels =FALSE)
	study_data = study_data[with(study_data, order(index)),]
	return(study_data)
}

createValidationData <- function(coh_base, val_size) {
	number_of_indices = length(coh_base$indices)
	validation_data = data.frame(gold =  rnorm(n = val_size, mean = raw_mean, sd = raw_stdev))
	
	validation_data$index = cut_number(x = validation_data$gold,n = number_of_indices, labels =FALSE)
	
	# 1st measurement
	measurement_error = rnorm(n = val_size, mean = 0, sd = coh_base$std_dev[1])
	validation_data$measured_exposure = validation_data$gold + measurement_error
	# 2nd measurement
	gold_errors2 = rnorm(n = val_size, mean = 0, sd = coh_base$std_dev[1])
	validation_data$gold_error2 = validation_data$gold + gold_errors2

	return (validation_data)
}

bootstrapRun <- function(coh_base, study_size, val_size, study_data) {
	number_of_indices = length(coh_base$indices)
	validation_index_size <- round(val_size/number_of_indices)
	study_index_size <- round(study_size/number_of_indices)
	
	# Make an 'updated' copy of the study database with the properties we want as in the validation data
	study_data_cp = updateStudyData(coh_base, study_data, number_of_indices)
	validation_data = createValidationData(coh_base, val_size)
	
	# overall results dataframe
	results_df <- data.frame()
	results <- as.data.frame(c(1:num_trials))
	colnames(results) <- c("NumTrial")
	results$valid_size <- rep(x=validation_index_size, times = num_trials)
	results$standard_deviation <- rep(x=coh_base$std_dev[1], times = num_trials)
	
	bootstrap  <- parLapply(cl, X=1:num_trials, fun=function(x){
		# Create the bootstrap, sampling from the validation data
		bootstrap_validation <- validation_data[sample(nrow(validation_data), val_size, replace=TRUE),]

		# calculating the means per index of bootstrap gold
		means_boots_list = vector(mode="list", length = number_of_indices)
		for (i in 1:number_of_indices) {
			means_boots_list[i] = mean(unname(unlist((split(x=bootstrap_validation$gold, f= as.factor(bootstrap_validation$index)))[i])))
		}

		# we are no longer bootstrapping the study data set. so we caclulate our beta regression here
		study_data_cp$gold_sample_ind_mean <- unlist(lapply(X=study_data_cp$index, FUN=function(index_val){
			output =  means_boots_list[index_val]
			}))
		reg_out_ind_mean <- lm(formula=foo~gold_sample_ind_mean, data=study_data_cp)

		# Create the validation data copy (because of parallelization) for the lambda regression calculation		
		reg_lambda <- lm(formula =gold~measured_exposure, data=bootstrap_validation)

		# Estimate the standard error of the corrected estimate as currently it doesnt take the 2nd order 
		# variability of lambda using the delta method :=>  variance = stdError * sqrt(numberofpeople) all squared
		var_lambda = (sqrt(val_size) * summary(reg_lambda)$coefficients["measured_exposure","Std. Error"])^2
		var_Beta = (sqrt(val_size) * summary(reg_out_ind_mean)$coefficients["gold_sample_ind_mean","Std. Error"])^2
		lambda_pure = unlist(unname(reg_lambda$coefficients["measured_exposure"]))
		beta_lambda_div_sq = (unname(unlist(reg_out_ind_mean$coefficients["gold_sample_ind_mean"]/(reg_lambda$coefficients["measured_exposure"])^2)))^2
		delta_variance = (var_Beta / (lambda_pure)^2) + beta_lambda_div_sq * var_lambda
		delta_stdError = sqrt(delta_variance)/sqrt(val_size) 

		# Return dual output into a list
		output = data.frame(c(reg_out_ind_mean$coefficients["gold_sample_ind_mean"], reg_lambda$coefficients["measured_exposure"], delta_stdError))
		return (output)
	})

	results$reg_cor_per_mean <- unlist(lapply(X = bootstrap, FUN = function(x){output = x[[1]][1]}))
	results$lambda <- unlist(lapply(X = bootstrap, FUN = function(x){output = x[[1]][2]}))
	results$corrected_cor <- results$reg_cor_per_mean/results$lambda
	results$delta_errors <- unlist(lapply(X = bootstrap, function(x){output = 2*1.96*(x[[1]][3])}))
	results_df <- rbind(results_df, results)
	
	# Summarizing the results dataframe
	temp_output <- aggregate(results_df[,4:7], by=list(valid_size = results_df$valid_size), quantile, probs=c(0.025,0.5,0.975), names=TRUE)
	final_output = data.frame(validation_size = temp_output[,1])

	for (k in 2:ncol(temp_output)){
	temp = as.data.frame(temp_output[,k])
	colnames(temp) <- paste(colnames(temp_output)[k], colnames(temp), sep = "_")
	final_output = cbind(final_output, temp)
	}
	final_output$val_size <- val_size
	return (final_output)
}

absDiff <- function(x,y){
	return (abs(x-y))
}

run_simulation <- function(numSeeds=25, number_of_indices=4){
	# for later summation of values in the results dataframe
	minmax_list = vector(mode="list", length = numSeeds)
	accuracy_list = vector(mode="list", length = numSeeds)
	minmax_list_cor = vector(mode="list", length = numSeeds)
	accuracy_list_cor = vector(mode="list", length = numSeeds)

	delta_errors_list = vector(mode="list", length = numSeeds)

	#progress bar for seeds completed
	pbt <- txtProgressBar(min = 1, max = numSeeds, style = 3)
	for (seeds in 1:numSeeds){
	  set.seed(seeds)
		results = data.frame()
		for (val_size in seq(from=100, to=400, by=20)){
			for (standard_dev in 5:15){
				# Defining a base generator for one cohort (which spawns validation, study data)
				coh_base = data.frame(indices = c(1:number_of_indices), std_dev = standard_dev)
				bootRunResult = bootstrapRun(coh_base, study_size, val_size, study_data)
				bootRunResult = cbind(bootRunResult, standard_dev)
				results = rbind(results, bootRunResult)
			}
		}

		# Create a heatmap of 'accuracy' through absolute difference in the 2.5% and 97.5% tiles
		results$minMaxDiff <- unlist(unname(mapply(FUN=absDiff, results$`reg_cor_per_mean_2.5%`, results$`reg_cor_per_mean_97.5%`)))
		results$minMaxDiff_cor <- unlist(unname(mapply(FUN=absDiff, results$`corrected_cor_2.5%`, results$`corrected_cor_97.5%`)))
		# Create a heatmap of 'accuracy' through absolute difference of the true 0.5 and the reported median value
		results$accuracyDiff <- unlist(unname(mapply(FUN=absDiff, set_beta, results$`reg_cor_per_mean_50%`)))
		results$accuracyDiff_cor <- unlist(unname(mapply(FUN=absDiff, set_beta, results$`corrected_cor_50%`)))

		minmax_list[[seeds]] <- (results$minMaxDiff)
		minmax_list_cor[[seeds]] <- (results$minMaxDiff_cor)
		accuracy_list[[seeds]] <- (results$accuracyDiff)
		accuracy_list_cor[[seeds]] <- (results$accuracyDiff_cor)

		delta_errors_list[[seeds]] <- (results$'delta_errors_50%')

		setTxtProgressBar(pbt, seeds)
	}
	close(pbt)

	# Then put the sum of the minmaxes together into the results dataframe
	results$minMaxDiff <- Reduce("+", x = minmax_list)
	results$accuracyDiff <- Reduce("+", x = accuracy_list)

	# Divide by number of seed for scaling
	results$minMaxDiff <- unlist(unname(lapply(X = results$minMaxDiff, FUN = function(x){
		output = x/numSeeds
		return(output)
		})))

	results$accuracyDiff <- unlist(unname(lapply(X = results$accuracyDiff, FUN = function(x){
		output = x/numSeeds
		return(output)
		})))

	# heatmap confidence
	plotTitle = paste(number_of_indices, "level", "Confidence for Uncorrected Beta", sep=" ")
	print(ggplot(results, aes(val_size, standard_dev )) + ggtitle(plotTitle) + 
	  geom_tile(aes(fill = minMaxDiff), color = "white") +
	  scale_fill_gradient(low = "green", high = "red") +
	  ylab("Standard Deviation") +
	  xlab("Validation Size") +
	  theme(legend.title = element_text(size = 10),
	        legend.text = element_text(size = 12),
	        plot.title = element_text(size=16),
	        axis.title=element_text(size=14,face="bold"),
	        axis.text.x = element_text(angle = 90, hjust = 1)) +
	  labs(fill = "Absolute Difference of 95% Interval"))

	# heatmap accuracy
	plotTitle = paste(number_of_indices, "level", "Accuracy for Uncorrected Beta", sep=" ")
	print(ggplot(results, aes(val_size, standard_dev )) + ggtitle(plotTitle) + 
	  geom_tile(aes(fill = accuracyDiff), color = "white") +
	  scale_fill_gradient(low = "green", high = "red") +
	  ylab("Standard Deviation") +
	  xlab("Validation Size") +
	  theme(legend.title = element_text(size = 10),
	        legend.text = element_text(size = 12),
	        plot.title = element_text(size=16),
	        axis.title=element_text(size=14,face="bold"),
	        axis.text.x = element_text(angle = 90, hjust = 1)) +
	  labs(fill = "Absolute Difference from Truth"))

	# Then put the sum of the minmaxes together into the results dataframe
	results$minMaxDiff_cor <- Reduce("+", x = minmax_list_cor)
	results$accuracyDiff_cor <- Reduce("+", x = accuracy_list_cor)

	results$delta_error <- Reduce("+", x = delta_errors_list)

	# Divide by number of seed for scaling
	results$minMaxDiff_cor <- unlist(unname(lapply(X = results$minMaxDiff_cor, FUN = function(x){
		output = x/numSeeds
		return(output)
		})))

	results$accuracyDiff_cor <- unlist(unname(lapply(X = results$accuracyDiff_cor, FUN = function(x){
		output = x/numSeeds
		return(output)
		})))

	results$delta_error <- unlist(unname(lapply(X = results$delta_error, FUN = function(x){
		output = x/numSeeds
		return(output)
		})))



	# heatmap confidence corrected
	plotTitle = paste(number_of_indices, "level", "Confidence for Corrected Beta Bootstrapped", sep=" ")
	print(ggplot(results, aes(val_size, standard_dev )) + ggtitle(plotTitle) + 
	  geom_tile(aes(fill = minMaxDiff_cor), color = "white") +
	  scale_fill_gradient(low = "green", high = "red") +
	  ylab("Standard Deviation") +
	  xlab("Validation Size") +
	  theme(legend.title = element_text(size = 10),
	        legend.text = element_text(size = 12),
	        plot.title = element_text(size=16),
	        axis.title=element_text(size=14,face="bold"),
	        axis.text.x = element_text(angle = 90, hjust = 1)) +
	  labs(fill = "Absolute Difference of 95% Interval"))

	# heatmap of delta interval
	plotTitle = paste(number_of_indices, "level", "Estimated Confidence for Corrected Beta \n through Delta Method", sep=" ")
	print(ggplot(results, aes(val_size, standard_dev )) + ggtitle(plotTitle) + 
	  geom_tile(aes(fill = delta_error), color = "white") +
	  scale_fill_gradient(low = "green", high = "red") +
	  ylab("Standard Deviation") +
	  xlab("Validation Size") +
	  theme(legend.title = element_text(size = 10),
	        legend.text = element_text(size = 12),
	        plot.title = element_text(size=16),
	        axis.title=element_text(size=14,face="bold"),
	        axis.text.x = element_text(angle = 90, hjust = 1)) +
	  labs(fill = "Delta Interval Calculation"))

	# heatmap accuracy corrected
	plotTitle = paste(number_of_indices, "level", "Accuracy for Corrected Beta", sep=" ")
	print(ggplot(results, aes(val_size, standard_dev )) + ggtitle(plotTitle) + 
	  geom_tile(aes(fill = accuracyDiff_cor), color = "white") +
	  scale_fill_gradient(low = "green", high = "red") +
	  ylab("Standard Deviation") +
	  xlab("Validation Size") +
	  theme(legend.title = element_text(size = 10),
	        legend.text = element_text(size = 12),
	        plot.title = element_text(size=16),
	        axis.title=element_text(size=14,face="bold"),
	        axis.text.x = element_text(angle = 90, hjust = 1)) +
	  labs(fill = "Absolute Difference from Truth"))

	return (results)
}

###############################################################################
########################### Simulation Section ################################
###############################################################################
num_trials <- 25
results_8 = run_simulation(numSeeds = 10, number_of_indices=8)


# stopcluster
stopCluster(cl)